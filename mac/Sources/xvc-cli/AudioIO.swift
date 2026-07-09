import AVFoundation

/// Mic capture -> 16 kHz mono float32, and converted audio -> speakers.
///
/// Phase 1 uses one engine and the default output device (headphones — monitoring your own
/// converted voice through speakers will feed back into the mic). Phase 2 re-points the
/// playout at the "XVC Mic" virtual device instead; see docs/MAC_APP.md §1.
final class AudioIO {
    let engine = AVAudioEngine()
    let jitter: JitterBuffer

    /// Called on the capture thread with 16 kHz mono PCM and the time the audio was
    /// captured (end of buffer, mach timebase).
    var onCapturedChunk: (([Float], Double) -> Void)?

    private let vcFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?

    /// Seconds of audio between the socket and the ear: what's queued in the jitter buffer
    /// plus what the output hardware holds. Used to turn "arrived" into "heard".
    var pendingPlayout: Double {
        Double(jitter.bufferedFrames) / 16000.0 + engine.outputNode.presentationLatency
    }

    private let deviceBufferFrames: Int?

    /// - Parameter deviceBufferFrames: optionally ask the input device for a smaller IO
    ///   buffer. Capture granularity comes from the device (typically 512 frames = 10.7 ms),
    ///   not from us, so leave this nil unless you are chasing the last few milliseconds.
    ///   It mutates a system-wide device property, so other audio apps see it too.
    init(jitter: JitterBuffer, deviceBufferFrames: Int? = nil) {
        self.jitter = jitter
        self.deviceBufferFrames = deviceBufferFrames
    }

    func start() throws {
        let input = engine.inputNode

        if let frames = deviceBufferFrames { setDefaultInputBufferFrames(UInt32(frames)) }

        if ProcessInfo.processInfo.environment["XVC_DEBUG_TAP"] != nil {
            let i = input.inputFormat(forBus: 0), o = input.outputFormat(forBus: 0)
            let line = "[fmt] inputNode.inputFormat \(i.sampleRate) Hz/\(i.channelCount)ch  "
                + "outputFormat \(o.sampleRate) Hz/\(o.channelCount)ch\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw XVCError("no input device (or microphone permission denied)")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: vcFormat) else {
            throw XVCError("cannot convert \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch to 16 kHz mono")
        }
        converter.downmix = true   // stereo mics exist; the server wants mono
        self.converter = converter

        // Playout: a source node pulls from the jitter buffer at whatever rate the output
        // device runs. The main mixer resamples 16 kHz -> device rate for us.
        let source = AVAudioSourceNode(format: vcFormat) { [jitter] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = buffers[0].mData else { return noErr }
            jitter.render(into: raw.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        self.sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: vcFormat)

        // Capture via a sink node, NOT installTap. Measured on macOS 15: installTap delivers
        // 4800-frame (100 ms) buffers regardless of its `bufferSize` argument, even though the
        // device is running 512-frame buffers. Audio that only materialises every 100 ms
        // cannot be sent sooner, so the server received input in clumps and returned it in
        // clumps — a ~100 ms latency tail. AVAudioSinkNode hands us the device's own
        // granularity. (docs/MAC_APP.md §1 assumed 5-20 ms here; the tap made that a lie.)
        let scratch = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16384)!
        let sink = AVAudioSinkNode { [weak self] timestamp, frameCount, audioBufferList in
            self?.handleCapture(audioBufferList,
                                frames: Int(frameCount),
                                hostTime: timestamp.pointee.mHostTime,
                                inputFormat: inputFormat,
                                scratch: scratch)
            return noErr
        }
        self.sinkNode = sink
        engine.attach(sink)
        engine.connect(input, to: sink, format: inputFormat)

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    /// Ask the default input device for a smaller IO buffer. The device clamps to its own
    /// supported range, so read the value back rather than assuming it took.
    private func setDefaultInputBufferFrames(_ frames: UInt32) {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &deviceAddress, 0, nil, &size, &device) == noErr else { return }

        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var current: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &bufferAddress, 0, nil, &size, &current)

        var wanted = frames
        let status = AudioObjectSetPropertyData(device, &bufferAddress, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &wanted)

        var applied: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &bufferAddress, 0, nil, &size, &applied)

        if ProcessInfo.processInfo.environment["XVC_DEBUG_TAP"] != nil {
            let line = "[dev] buffer frames: was \(current), asked \(frames), now \(applied) (status \(status))\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }

    private var debugTapLast = 0.0
    private var debugTapCount = 0

    private func handleCapture(_ audioBufferList: UnsafePointer<AudioBufferList>,
                               frames: Int,
                               hostTime: UInt64,
                               inputFormat: AVAudioFormat,
                               scratch: AVAudioPCMBuffer) {
        guard let converter, frames > 0, frames <= Int(scratch.frameCapacity) else { return }

        if ProcessInfo.processInfo.environment["XVC_DEBUG_TAP"] != nil, debugTapCount < 10 {
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let gap = debugTapLast > 0 ? (now - debugTapLast) * 1000 : 0
            let line = "[tap] gap \(String(format: "%6.1f", gap)) ms  in \(frames) frames "
                + "(\(String(format: "%.1f", Double(frames) / inputFormat.sampleRate * 1000)) ms)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
            debugTapLast = now
            debugTapCount += 1
        }

        // The sink node hands us a raw buffer list; AVAudioConverter wants an AVAudioPCMBuffer.
        let incoming = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        scratch.frameLength = AVAudioFrameCount(frames)
        guard let dst = scratch.floatChannelData else { return }
        for channel in 0..<min(Int(inputFormat.channelCount), incoming.count) {
            guard let src = incoming[channel].mData else { continue }
            dst[channel].update(from: src.assumingMemoryBound(to: Float.self), count: frames)
        }

        let ratio = vcFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: vcFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return scratch
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else {
            if let error { FileHandle.standardError.write("convert failed: \(error)\n".data(using: .utf8)!) }
            return
        }

        // Timestamp the END of the buffer: that is when this audio finished existing in the
        // real world. Using the start would understate latency by the buffer's duration.
        let capturedAt = AVAudioTime.seconds(forHostTime: hostTime) + Double(frames) / inputFormat.sampleRate

        let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        onCapturedChunk?(pcm, capturedAt)
    }
}

struct XVCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
