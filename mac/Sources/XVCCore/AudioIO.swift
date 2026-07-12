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
/// device. This is what the README prescribes.
public final class AudioIO {
    public private(set) var captureEngine = AVAudioEngine()
    public private(set) var playoutEngine = AVAudioEngine()
    public let jitter: JitterBuffer

    /// Called on the capture thread with 16 kHz mono PCM and the time the audio was
    /// captured (end of buffer, mach timebase).
    public var onCapturedChunk: (([Float], Double) -> Void)?

    private let vcFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?

    private let deviceBufferFrames: Int?
    private let mute: Bool
    private let outputDevice: AudioDevices.Device?
    private let inputDevice: AudioDevices.Device?

    /// Fired when CoreAudio reconfigured underneath us and we rebuilt. Callers re-prime.
    public var onReconfigured: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var isRebuilding = false
    private var rebuildScheduled = false
    public private(set) var rebuildCount = 0

    /// Seconds of audio between the socket and the ear: what's queued in the jitter buffer
    /// plus what the output hardware holds. Used to turn "arrived" into "heard".
    public var pendingPlayout: Double {
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
    public init(jitter: JitterBuffer,
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
    public var inputDeviceName: String {
        AudioDevices.currentDevice(of: captureEngine.inputNode.audioUnit)?.name ?? "default"
    }
    public var outputDeviceName: String {
        AudioDevices.currentDevice(of: playoutEngine.outputNode.audioUnit)?.name ?? "default"
    }

    public func start() throws {
        // The initial engine.start() posts its own configuration change, which would arrive
        // just after we register observers and trigger a pointless rebuild on every launch
        // (observed: "#1" at startup, 2.4 s latency spike, ~10 s to recover). Swallow it the
        // same way rebuild() swallows its own echo.
        isRebuilding = true
        try startPlayout()
        try startCapture()
        observeConfigurationChanges()
        startWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRebuilding = false
        }
    }

    public func stop() {
        watchdog?.cancel()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        captureEngine.stop()
        playoutEngine.stop()
    }

    private func startWatchdog() {
        let now = machNow()
        healthLock.lock(); lastChunkAt = now; lastNonzeroAt = now; healthLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkCaptureHealth() }
        timer.resume()
        watchdog = timer
    }

    private func checkCaptureHealth() {
        guard !isRebuilding, !rebuildScheduled else { return }
        let now = machNow()
        healthLock.lock()
        let sinceChunk = now - lastChunkAt
        let sinceNonzero = now - lastNonzeroAt
        healthLock.unlock()

        if sinceNonzero < 1.0 { watchdogStrikes = 0 }

        // Exponential backoff so a genuinely muted mic doesn't rebuild forever.
        let zeroGrace = 3.0 * pow(2.0, Double(min(watchdogStrikes, 4)))
        let reason: String?
        if sinceChunk > 1.5 {
            reason = String(format: "no capture callbacks for %.1f s", sinceChunk)
        } else if sinceNonzero > zeroGrace {
            reason = String(format: "mic delivering pure zeros for %.1f s", sinceNonzero)
        } else {
            reason = nil
        }
        if let reason {
            watchdogStrikes += 1
            onReconfigured?("capture watchdog: \(reason); forcing capture rebuild")
            scheduleRebuild(capture: true)
        }
    }

    // MARK: - surviving device changes
    //
    // CoreAudio reconfigures when a device is added, removed, or seized -- and when a call
    // app enables voice processing on the built-in mic. AVAudioEngine responds by STOPPING,
    // so we must rebuild. But rebuild ONLY the engine that changed: the far-end app reads
    // XVC Mic continuously, and tearing down the playout engine because the *microphone*
    // changed yanks the device's stream out from under that reader mid-call. Some readers
    // never recover -- observed as "one hello, then permanent silence" while every client
    // stat stayed green (we were rendering into XVC Mic; the far app had stopped listening).
    private var needsCaptureRebuild = false
    private var needsPlayoutRebuild = false

    // Capture-health watchdog. AVAudioEngineConfigurationChange does NOT always fire: a
    // nominal sample-rate change on the pinned mic made the capture engine deliver pure
    // zeros with no notification and no error (reproduced deterministically). The input
    // signal itself is the only trustworthy liveness indicator, so we watch it and force a
    // capture rebuild when it dies. A real mic always has a noise floor (~0.017 measured);
    // exact zeros mean a dead engine, not a quiet room.
    private let healthLock = NSLock()
    private var lastChunkAt: Double = 0
    private var lastNonzeroAt: Double = 0
    private var watchdog: DispatchSourceTimer?
    private var watchdogStrikes = 0

    private func observeConfigurationChanges() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        let capture = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: captureEngine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild(capture: true)
        }
        let playout = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: playoutEngine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild(capture: false)
        }
        observers = [capture, playout]
    }

    /// Restarting an engine posts its own configuration change, so a naive handler rebuilds
    /// forever. Coalesce notifications and ignore the echo of our own restarts.
    private func scheduleRebuild(capture: Bool) {
        guard !isRebuilding else { return }
        if capture { needsCaptureRebuild = true } else { needsPlayoutRebuild = true }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        isRebuilding = true
        rebuildCount += 1
        let doCapture = needsCaptureRebuild
        let doPlayout = needsPlayoutRebuild
        needsCaptureRebuild = false
        needsPlayoutRebuild = false

        // Recreate the affected engine; do NOT restart the old instance. A stopped engine
        // reconnected after a device change can resume with its input delivering pure zeros
        // and no error from any API.
        var rebuilt: [String] = []
        do {
            if doPlayout {
                playoutEngine.stop()
                sourceNode = nil
                playoutEngine = AVAudioEngine()
                jitter.reset()   // playout restarted from scratch: buffered audio is stale
                try startPlayout()
                rebuilt.append("playout")
            }
            if doCapture {
                captureEngine.stop()
                sinkNode = nil
                captureEngine = AVAudioEngine()
                try startCapture()
                rebuilt.append("capture")
                let now = machNow()
                healthLock.lock(); lastChunkAt = now; lastNonzeroAt = now; healthLock.unlock()
            }
            onReconfigured?("rebuilt \(rebuilt.joined(separator: "+")) engine (#\(rebuildCount))"
                + (doPlayout ? "" : " — playout untouched, XVC Mic stream unbroken"))
        } catch {
            onReconfigured?("rebuild failed: \(error.localizedDescription)")
        }
        // Fresh engines need fresh observers, and our own start() posts a change — swallow it.
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

        var peak: Float = 0
        for sample in pcm { peak = max(peak, abs(sample)) }
        let now = machNow()
        healthLock.lock()
        lastChunkAt = now
        if peak > 1e-6 { lastNonzeroAt = now }
        healthLock.unlock()

        onCapturedChunk?(pcm, capturedAt)
    }
}

public struct XVCError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
