import AVFoundation
import Foundation
import XVCCore

/// The conversion engine behind the menu bar. Owns the audio pipeline (XVCCore.AudioIO +
/// JitterBuffer) and the server connection, and switches between two modes into the same
/// "XVC Mic" playout device:
///
///   passthrough — mic → XVC Mic directly, no network (Convert OFF)
///   converting  — mic → server → XVC Mic (Convert ON)
///
/// Both feed the one jitter buffer, so the output device never sees a gap when we flip
/// modes (docs/MAC_APP.md §3, §3.1). Callbacks come off audio/network threads; UI state is
/// published on the main actor.
@MainActor
final class Engine: ObservableObject {
    enum State: Equatable {
        case idle
        case passthrough              // real voice flowing to XVC Mic
        case connecting               // Convert ON requested, server not ready yet
        case converting               // converted voice flowing
        case error(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { log("state -> \(state)") }
    }
    @Published private(set) var inputLevel: Float = 0     // 0…1 peak, decays
    @Published private(set) var latencyMs: Double = 0

    private func log(_ s: String) {
        FileHandle.standardError.write("[engine] \(s)\n".data(using: .utf8)!)
    }
    private var capturedChunks = 0

    private let settings: AppSettings
    private var audio: AudioIO?
    private let jitter = JitterBuffer()
    private let tracker = LatencyTracker()

    private var client: XVCClient?
    private var socket: URLSessionWebSocketTask?

    // `converting` is read on the realtime capture thread, so keep it a plain atomic-ish
    // flag guarded by a lock rather than the @Published main-actor state.
    private let modeLock = NSLock()
    private var _converting = false
    private var convertRequested = false
    private var reconnectTask: Task<Void, Never>?

    init(settings: AppSettings) { self.settings = settings }

    // MARK: - lifecycle

    /// Bring the pipeline up in passthrough. Idempotent.
    ///
    /// Microphone permission must exist BEFORE the AVAudioEngine is created. macOS does not
    /// feed audio to an already-running engine when permission is granted mid-session, so a
    /// first-run app that starts capture then asks would capture silence until relaunch (we
    /// hit exactly this). Requesting first, and building the engine only once authorized,
    /// removes the relaunch.
    func start() {
        guard audio == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            reallyStart()
        case .notDetermined:
            state = .connecting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.reallyStart() }
                    else { self.state = .error("Microphone access denied") }
                }
            }
        case .denied, .restricted:
            state = .error("Microphone access off — enable it in System Settings › Privacy › Microphone")
        @unknown default:
            reallyStart()
        }
    }

    private func reallyStart() {
        guard audio == nil else { return }
        guard let xvcMic = AudioDevices.findOutput(named: "XVC Mic") else {
            state = .error("\"XVC Mic\" device not found — install the driver")
            return
        }
        let input = resolveInput()
        let io = AudioIO(jitter: jitter, outputDevice: xvcMic, inputDevice: input)
        io.onCapturedChunk = { [weak self] pcm, capturedAt in self?.onCaptured(pcm, capturedAt) }
        io.onReconfigured = { [weak self] msg in Task { @MainActor in self?.handleReconfigured(msg) } }
        do {
            try io.start()
            audio = io
            setConverting(false)
            state = .passthrough
            log("started: in=\(io.inputDeviceName) out=\(io.outputDeviceName)")
            if convertRequested { connect() }   // user asked to convert during the mic prompt
        } catch {
            log("start failed: \(error)")
            state = .error(error.localizedDescription)
        }
    }

    func stop() {
        reconnectTask?.cancel()
        closeSocket()
        audio?.stop()
        audio = nil
        setConverting(false)
        state = .idle
    }

    /// A physical mic — never XVC Mic, or we'd capture our own output.
    private func resolveInput() -> AudioDevices.Device? {
        let wanted = settings.inputDeviceName
        if !wanted.isEmpty, wanted != "XVC Mic", let d = AudioDevices.findInput(named: wanted) { return d }
        if let def = AudioDevices.defaultInput(), def.name != "XVC Mic" { return def }
        // System default is XVC Mic (bad): fall back to any real input.
        return AudioDevices.all().first { $0.inputChannels > 0 && $0.name != "XVC Mic" }
    }

    // MARK: - the Convert toggle

    var isConverting: Bool { convertRequested }

    func toggleConvert() { setConvert(!convertRequested) }

    func setConvert(_ on: Bool) {
        convertRequested = on
        if audio == nil { start() }
        if on {
            guard settings.isConfigured else {
                state = .error("Pick a server and a target voice first")
                convertRequested = false
                return
            }
            connect()
        } else {
            reconnectTask?.cancel()
            closeSocket()
            setConverting(false)               // capture feeds jitter directly again
            if audio != nil { state = .passthrough }
        }
    }

    // MARK: - server connection

    private func connect() {
        state = .connecting
        let host = settings.host, port = settings.port, token = settings.token
        let trust = settings.trustSelfSigned
        guard let target = settings.selectedTarget else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var backoff: UInt64 = 500_000_000   // 0.5s, doubles to 8s
            while !Task.isCancelled {
                do {
                    try await self?.attemptConnect(host: host, port: port, token: token,
                                                   trust: trust, target: target)
                    return
                } catch {
                    guard let self, self.convertRequested, !Task.isCancelled else { return }
                    await MainActor.run { self.state = .error("reconnecting… (\(error.localizedDescription))") }
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 8_000_000_000)
                }
            }
        }
    }

    private func attemptConnect(host: String, port: Int, token: String,
                                trust: Bool, target: TargetVoice) async throws {
        log("connecting host=\(host):\(port) trust=\(trust) token=\(token.isEmpty ? "none" : "set")")
        let client = XVCClient(host: host, port: port, allowSelfSigned: trust, token: token)
        self.client = client

        // Upload the target if we don't have a live handle. target_id doesn't survive a
        // server restart, so a stale one yields "Unknown target_id" and we re-upload.
        var targetID = target.targetID
        if targetID == nil {
            log("uploading target \(target.name) …")
            targetID = try await uploadTarget(client, target)
            log("target uploaded: \(targetID!)")
        }

        let task: URLSessionWebSocketTask
        do {
            log("opening stream with \(targetID!) …")
            task = try await client.openStream(targetID: targetID!, sourceRate: 16000)
        } catch {
            log("openStream failed (\(error)); re-uploading target and retrying")
            targetID = try await uploadTarget(client, target)
            task = try await client.openStream(targetID: targetID!, sourceRate: 16000)
        }
        log("stream ready")
        guard convertRequested, !Task.isCancelled else { task.cancel(with: .normalClosure, reason: nil); return }

        socket = task
        setConverting(true)
        state = .converting
        pump(task)
    }

    private func uploadTarget(_ client: XVCClient, _ target: TargetVoice) async throws -> String {
        let result = try await client.loadTarget(wavURL: URL(fileURLWithPath: target.wavPath))
        // Cache the fresh handle back into settings.
        var list = settings.targets
        if let i = list.firstIndex(where: { $0.id == target.id }) {
            list[i].targetID = result.id
            settings.targets = list
        }
        return result.id
    }

    private func pump(_ task: URLSessionWebSocketTask) {
        receiveLoop(task, onPCM: { [weak self] pcm, arrivedAt in
            guard let self else { return }
            self.jitter.write(pcm)
            let pending = self.audio?.pendingPlayout ?? 0
            if let lat = self.tracker.recordReceive(frames: pcm.count, now: arrivedAt, pendingPlayout: pending) {
                Task { @MainActor in self.latencyMs = lat * 1000 }
            }
        }, onClose: { [weak self] reason in
            Task { @MainActor in self?.handleSocketClosed(reason) }
        })
    }

    private func handleSocketClosed(_ reason: String?) {
        guard convertRequested else { return }   // an intentional OFF closed it
        setConverting(false)                       // fall back to passthrough so the far end
        state = .error("connection lost — reconnecting")   // hears the real mic, not silence
        connect()
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: - capture callback (realtime thread)

    private func onCaptured(_ pcm: [Float], _ capturedAt: Double) {
        var peak: Float = 0
        for s in pcm { peak = max(peak, abs(s)) }
        Task { @MainActor in self.inputLevel = max(peak, self.inputLevel * 0.6) }

        capturedChunks += 1
        if capturedChunks % 100 == 1 {   // ~1/s at 11ms chunks
            modeLock.lock(); let c = _converting; modeLock.unlock()
            log(String(format: "capture #%d peak=%.3f mode=%@ socket=%@",
                       capturedChunks, peak, c ? "convert" : "passthru", socket == nil ? "nil" : "open"))
        }

        modeLock.lock(); let converting = _converting; modeLock.unlock()
        if converting, let task = socket {
            tracker.recordSend(frames: pcm.count, capturedAt: capturedAt)
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            task.send(.data(data)) { _ in }
        } else {
            // Passthrough: the real voice goes straight to XVC Mic.
            jitter.write(pcm)
        }
    }

    private func setConverting(_ on: Bool) {
        modeLock.lock(); _converting = on; modeLock.unlock()
        if !on { jitter.reset() }   // dropping stale converted audio on the way back to raw
    }

    private func handleReconfigured(_ msg: String) {
        // AudioIO already rebuilt the affected engine; nothing to do but note it if broken.
        if msg.contains("failed") { state = .error(msg) }
    }
}
