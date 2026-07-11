import AVFoundation

/// Mic capture -> 16 kHz mono float32, and converted audio -> an output device.
///
/// **Two engines, deliberately.** On macOS an AVAudioEngine's `inputNode` and `outputNode`
/// share one I/O audio unit, so `kAudioOutputUnitProperty_CurrentDevice` re-points *both*.
/// With a single engine, selecting "XVC Mic" as the output silently made it the input too:
/// the mic then read XVC Mic's own loopback (our converted audio) and fed it back to the
/// server. The tell was the reported mic rate flipping from 48 kHz to 16 kHz.
///
/// So `captureEngine` stays on the default input device and `playoutEngine` owns the output
/// device. This is what docs/MAC_APP.md §1 prescribes.
final class AudioIO {
    private(set) var captureEngine = AVAudioEngine()
    private(set) var playoutEngine = AVAudioEngine()
    let jitter: JitterBuffer

    /// Called on the capture thread with 16 kHz mono PCM and the time the audio was
    /// captured (end of buffer, mach timebase).
    var onCapturedChunk: (([Float], Double) -> Void)?

    private let vcFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?

    private let deviceBufferFrames: Int?
    private let mute: Bool
    private let outputDevice: AudioDevices.Device?
    private let inputDevice: AudioDevices.Device?

    /// Fired when CoreAudio reconfigured underneath us and we rebuilt. Callers re-prime.
    var onReconfigured: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var isRebuilding = false
    private var rebuildScheduled = false
    private(set) var rebuildCount = 0

    /// Seconds of audio between the socket and the ear: what's queued in the jitter buffer
    /// plus what the output hardware holds. Used to turn "arrived" into "heard".
    var pendingPlayout: Double {
        Double(jitter.bufferedFrames) / 16000.0 + playoutEngine.outputNode.presentationLatency
    }

    /// - Parameters:
    ///   - deviceBufferFrames: optionally ask the input device for a smaller IO buffer.
    ///     Capture granularity comes from the device (typically 512 frames = 10.7 ms), so
    ///     leave nil unless chasing the last few ms. It mutates a system-wide property.
    ///   - mute: render the converted audio at zero volume. The engine still pulls the
    ///     jitter buffer on the same schedule, so timing is unchanged — it just lets you
    ///     measure latency on speakers without the mic hearing the output.
    ///   - outputDevice: where to render the converted voice. nil = default output
    ///     (headphones, Phase 1). Pass "XVC Mic" for Phase 2: what we render to its output
    ///     side appears at its input side, which meeting apps read.
    init(jitter: JitterBuffer,
         deviceBufferFrames: Int? = nil,
         mute: Bool = false,
         outputDevice: AudioDevices.Device? = nil,
         inputDevice: AudioDevices.Device? = nil) {
        self.jitter = jitter
        self.deviceBufferFrames = deviceBufferFrames
        self.mute = mute
        self.outputDevice = outputDevice
        self.inputDevice = inputDevice
    }

    /// What the engines actually ended up bound to. Always report these: the loopback bug
    /// above was invisible precisely because nothing printed the input device.
    var inputDeviceName: String {
        AudioDevices.currentDevice(of: captureEngine.inputNode.audioUnit)?.name ?? "default"
    }
    var outputDeviceName: String {
        AudioDevices.currentDevice(of: playoutEngine.outputNode.audioUnit)?.name ?? "default"
    }

    func start() throws {
        // The initial engine.start() posts its own configuration change, which would arrive
        // just after we register observers and trigger a pointless rebuild on every launch
        // (observed: "#1" at startup, 2.4 s latency spike, ~10 s to recover). Swallow it the
        // same way rebuild() swallows its own echo.
        isRebuilding = true
        try startPlayout()
        try startCapture()
        observeConfigurationChanges()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRebuilding = false
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        captureEngine.stop()
        playoutEngine.stop()
    }

    // MARK: - surviving device changes
    //
    // CoreAudio reconfigures when a device is added, removed, or seized -- and crucially when
    // a meeting app selects "XVC Mic" as its microphone, which changes the system default
    // input. AVAudioEngine responds by STOPPING. Without this, both engines die mid-call: the
    // jitter buffer freezes, we stop sending, and the far end hears silence with no error
    // printed anywhere. docs/MAC_APP.md §4.
    private func observeConfigurationChanges() {
        for engine in [captureEngine, playoutEngine] {
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.scheduleRebuild(reason: engine === self.captureEngine ? "capture" : "playout")
            }
            observers.append(token)
        }
    }

    /// Restarting an engine itself posts a configuration change, so a naive handler rebuilds
    /// forever: observed as alternating "playout reconfigured"/"capture reconfigured" lines,
    /// each one resetting the jitter buffer and cutting the outgoing audio. Coalesce the
    /// notifications and ignore the ones our own restart provokes.
    private func scheduleRebuild(reason: String) {
        guard !isRebuilding, !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild(reason: reason)
        }
    }

    private func rebuild(reason: String) {
        isRebuilding = true
        rebuildCount += 1
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        captureEngine.stop()
        playoutEngine.stop()
        sourceNode = nil
        sinkNode = nil

        // Recreate the engines, do NOT reuse them. A stopped engine reconnected after a
        // device change can come back with its input node delivering pure zeros: the
        // pipeline stats look healthy (silence converts to silence), the far end hears
        // nothing, and no API reports an error. Observed on the first real call.
        captureEngine = AVAudioEngine()
        playoutEngine = AVAudioEngine()
        jitter.reset()
        do {
            try startPlayout()
            try startCapture()
            onReconfigured?("\(reason) engine reconfigured; rebuilt fresh engines (#\(rebuildCount))")
        } catch {
            onReconfigured?("rebuild failed: \(error.localizedDescription)")
        }
        // The new engines need observers, and our own start() posts a configuration
        // change — swallow that echo.
        observeConfigurationChanges()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRebuilding = false
        }
    }

    // MARK: - playout (converted audio -> output device)

    private func startPlayout() throws {
        // Must happen before the engine starts: CoreAudio will not re-point a running unit.
        if let outputDevice {
            try AudioDevices.setOutputDevice(playoutEngine, to: outputDevice)
        }

        let source = AVAudioSourceNode(format: vcFormat) { [jitter] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = buffers[0].mData else { return noErr }
            let mono = raw.assumingMemoryBound(to: Float.self)
            jitter.render(into: mono, frames: Int(frameCount))

            // A virtual mic is 2-channel; put the same mono signal on every channel.
            for channel in 1..<buffers.count {
                if let dst = buffers[channel].mData {
                    dst.assumingMemoryBound(to: Float.self).update(from: mono, count: Int(frameCount))
                }
            }
            return noErr
        }
        self.sourceNode = source
        playoutEngine.attach(source)

        // The main mixer resamples 16 kHz -> whatever rate the output device runs at.
        playoutEngine.connect(source, to: playoutEngine.mainMixerNode, format: vcFormat)
        if mute { playoutEngine.mainMixerNode.outputVolume = 0 }

        playoutEngine.prepare()
        try playoutEngine.start()
    }

    // MARK: - capture (mic -> 16 kHz mono)

    private func startCapture() throws {
        if let frames = deviceBufferFrames { setDefaultInputBufferFrames(UInt32(frames)) }

        let input = captureEngine.inputNode
        // Bind to a real microphone explicitly. Following the system default is unsafe: a
        // meeting app that picks "XVC Mic" as its mic changes that default, and we would then
        // capture our own converted output.
        if let inputDevice {
            try AudioDevices.setInputDevice(captureEngine, to: inputDevice)
        }
        // Read the format AFTER re-pointing the device, and read the node's *hardware* format.
        // outputFormat(forBus:) goes stale across a device switch, and connecting with it
        // throws "Input HW format and tap format not matching" — a hard crash at startup.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw XVCError("no input device (or microphone permission denied)")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: vcFormat) else {
            throw XVCError("cannot convert \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch to 16 kHz mono")
        }
        converter.downmix = true   // stereo mics exist; the server wants mono
        self.converter = converter

        // Capture via a sink node, NOT installTap. Measured on macOS 15: installTap delivers
        // 4800-frame (100 ms) buffers regardless of its `bufferSize` argument, even though the
        // device runs 512-frame buffers. Audio that only materialises every 100 ms cannot be
        // sent sooner, so the server received input in clumps and returned it in clumps — a
        // ~100 ms latency tail. AVAudioSinkNode hands us the device's own granularity.
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
        captureEngine.attach(sink)
        captureEngine.connect(input, to: sink, format: inputFormat)

        captureEngine.prepare()
        try captureEngine.start()
    }

    /// Ask the default input device for a smaller IO buffer. The device clamps to its own
    /// supported range.
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
        var wanted = frames
        AudioObjectSetPropertyData(device, &bufferAddress, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &wanted)
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
