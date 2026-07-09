import AVFoundation
import Foundation

// Phase 1 (docs/ROADMAP.md): mic -> 16 kHz -> WebSocket -> jitter buffer -> HEADPHONES.
// No virtual mic, no UI. The gate is p95 < 500 ms over 2 minutes with no growing drift.
//
// Wear headphones. Monitoring your converted voice on speakers feeds it back into the mic.

struct Options {
    var host = ProcessInfo.processInfo.environment["XVC_HOST"] ?? ""
    var port = 5002
    var targetWav: String?
    var targetID: String?
    var insecure = false
    var seconds = 120.0
    var primeMs = 180.0
    var troughMs = 80.0   // a starting guess; the buffer grows it on each underrun
    var deviceBufferFrames: Int?
    var mute = false
    var outputDevice: String?
    var inputDevice: String?
    var listDevices = false
}

func parseArguments() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    if args.contains("--help") || args.contains("-h") {
        print("""
        xvc-cli — Phase-1 latency prototype

          --target-wav <path>   target speaker WAV, uploaded via load-target
          --target-id <id>      reuse an existing target_id instead of uploading
          --host <host>         server host; defaults to $XVC_HOST
          --port <port>         default 5002
          --insecure            trust the dev server's self-signed cert
          --seconds <n>         run duration, default 120 (the gate)
          --prime-ms <n>        jitter buffer prime depth, default 180
          --trough-ms <n>       starting buffer trough, default 80 (grows on underrun)
          --device-buffer <n>   ask the mic for an N-frame IO buffer (system-wide; rarely needed)
          --mute                measure latency without playing audio (no headphones needed)
          --output-device <name>  render into this device instead of the speakers, e.g. "XVC Mic"
          --input-device <name>   capture from this mic (default: the system default input)
          --list-devices        print the audio devices this Mac has, and exit

        Wear headphones. Grant Terminal microphone access in System Settings.
        """)
        exit(0)
    }

    if let v = value("--host") { options.host = v }
    if let v = value("--port"), let p = Int(v) { options.port = p }
    if let v = value("--target-wav") { options.targetWav = v }
    if let v = value("--target-id") { options.targetID = v }
    if let v = value("--seconds"), let s = Double(v) { options.seconds = s }
    if let v = value("--prime-ms"), let m = Double(v) { options.primeMs = m }
    if let v = value("--trough-ms"), let m = Double(v) { options.troughMs = m }
    if let v = value("--device-buffer"), let f = Int(v) { options.deviceBufferFrames = f }
    options.insecure = args.contains("--insecure")
    if let v = value("--output-device") { options.outputDevice = v }
    if let v = value("--input-device") { options.inputDevice = v }
    options.mute = args.contains("--mute")
    options.listDevices = args.contains("--list-devices")
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let options = parseArguments()

if options.listDevices {
    for d in AudioDevices.all() {
        let kind = [d.inputChannels > 0 ? "in:\(d.inputChannels)" : nil,
                    d.outputChannels > 0 ? "out:\(d.outputChannels)" : nil]
            .compactMap { $0 }.joined(separator: " ")
        print("  \(d.name.padding(toLength: max(28, d.name.count), withPad: " ", startingAt: 0)) \(kind)")
    }
    exit(0)
}

guard !options.host.isEmpty else {
    fail("no server host: pass --host or set XVC_HOST")
}
guard options.targetWav != nil || options.targetID != nil else {
    fail("need --target-wav or --target-id (see --help)")
}

let client = XVCClient(host: options.host, port: options.port, allowSelfSigned: options.insecure)

// 1. Register the target voice.
var targetID: String
if let existing = options.targetID {
    targetID = existing
    print("[xvc] reusing target_id=\(existing)")
} else {
    let url = URL(fileURLWithPath: options.targetWav!)
    do {
        let target = try await client.loadTarget(wavURL: url)
        targetID = target.id
        print("[xvc] target_id=\(target.id) (\(String(format: "%.1f", target.duration))s)")
    } catch {
        fail("\(error.localizedDescription)")
    }
}

// 2. Open the stream and wait for {"status":"ready"} before touching the mic.
let socket: URLSessionWebSocketTask
do {
    socket = try await client.openStream(targetID: targetID, sourceRate: 16000)
    print("[xvc] stream ready — wss://\(options.host):\(options.port)")
} catch {
    fail("\(error.localizedDescription)")
}

// 3. Wire the audio path.
/// Set from the socket callbacks and the SIGINT handler; read from the async report loop.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReason: String?
    private var isStopped = false

    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return isStopped }
    var reason: String? { lock.lock(); defer { lock.unlock() }; return storedReason }

    func stop(_ reason: String? = nil) {
        lock.lock()
        if storedReason == nil { storedReason = reason }
        isStopped = true
        lock.unlock()
    }
}

let jitter = JitterBuffer(primeFrames: Int(options.primeMs / 1000.0 * 16000),
                          targetTroughFrames: Int(options.troughMs / 1000.0 * 16000))
var outputDevice: AudioDevices.Device?
if let wanted = options.outputDevice {
    guard let found = AudioDevices.findOutput(named: wanted) else {
        fail("no output device named \"\(wanted)\". Run --list-devices to see what exists.")
    }
    outputDevice = found
    print("[xvc] rendering into \"\(found.name)\" (uid \(found.uid), \(found.outputChannels)ch out / \(found.inputChannels)ch in)")
}

// Resolve the mic ONCE, up front, and pin the engine to it. If a meeting app later selects
// "XVC Mic" as its microphone, macOS changes the default input — we must not follow.
var inputDevice: AudioDevices.Device?
if let wanted = options.inputDevice {
    guard let found = AudioDevices.findInput(named: wanted) else {
        fail("no input device named \"\(wanted)\". Run --list-devices to see what exists.")
    }
    inputDevice = found
} else {
    inputDevice = AudioDevices.defaultInput()
}
if let inputDevice, let outputDevice, inputDevice.id == outputDevice.id {
    fail("input and output are both \"\(inputDevice.name)\" — the mic would hear its own output")
}
if let inputDevice { print("[xvc] capturing from \"\(inputDevice.name)\" (pinned)") }

let audio = AudioIO(jitter: jitter,
                    deviceBufferFrames: options.deviceBufferFrames,
                    mute: options.mute,
                    outputDevice: outputDevice,
                    inputDevice: inputDevice)

audio.onReconfigured = { message in
    print("[xvc] \(message)")
}
let tracker = LatencyTracker()
let stopSignal = StopSignal()

// Debug: how evenly does the mic tap actually fire? A ragged tap makes the server see
// bursts of input, which makes windows complete in clumps.
let tapIntervals = TapIntervals()

audio.onCapturedChunk = { pcm, capturedAt in
    tapIntervals.mark(machNow())
    tracker.recordSend(frames: pcm.count, capturedAt: capturedAt)
    let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    socket.send(.data(data)) { error in
        if let error { stopSignal.stop("send failed: \(error.localizedDescription)") }
    }
}

receiveLoop(socket) { pcm, arrivedAt in
    jitter.write(pcm)
    // pendingPlayout now includes this frame, so it measures the frame's LAST sample —
    // matching tools/probe_stream.py's convention.
    tracker.recordReceive(frames: pcm.count, now: arrivedAt, pendingPlayout: audio.pendingPlayout)
} onClose: { reason in
    stopSignal.stop(reason ?? "socket closed")
}

do {
    try audio.start()
} catch {
    fail("\(error.localizedDescription)")
}

let inputFormat = audio.captureEngine.inputNode.outputFormat(forBus: 0)
print(String(format: "[xvc] in  \"%@\" %.0f Hz / %d ch -> 16 kHz",
             audio.inputDeviceName, inputFormat.sampleRate, inputFormat.channelCount))
print(String(format: "[xvc] out \"%@\" | hw latency %.1f ms | prime %.0f ms",
             audio.outputDeviceName,
             audio.playoutEngine.outputNode.presentationLatency * 1000, options.primeMs))
if audio.inputDeviceName == audio.outputDeviceName {
    fail("input and output both bound to \"\(audio.inputDeviceName)\" — the mic would hear its own output")
}
print("[xvc] speak now — rolling latency every 2 s (Ctrl-C to stop early)\n")

// 4. Report while it runs.
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { stopSignal.stop("interrupted") }
interrupt.resume()
signal(SIGINT, SIG_IGN)

let deadline = Date().addingTimeInterval(options.seconds)
reportLoop: while Date() < deadline && !stopSignal.stopped {
    // Poll in slices so Ctrl-C feels responsive, but only report every 2 s.
    for _ in 0..<8 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if stopSignal.stopped { break reportLoop }
    }
    if let r = tracker.rolling() {
        print(String(format: "  p50 %6.1f ms   p95 %6.1f ms   buffer %4d frames   underruns %d",
                     r.p50 * 1000, r.p95 * 1000, jitter.bufferedFrames, jitter.underruns))
    } else {
        print("  (no audio back yet — is the mic capturing? check System Settings ▸ Privacy ▸ Microphone)")
    }
}

audio.stop()
socket.cancel(with: .normalClosure, reason: nil)

if let reason = stopSignal.reason {
    print("\n[xvc] stream ended: \(reason)")
}

// Skip ~3 s: the jitter buffer priming and any server-side warm-up are startup transients,
// not steady-state latency. Bursts are 120 ms, so 25 frames ≈ 3 s.
guard let s = tracker.summary(skip: 25) else {
    fail("not enough audio came back to measure — check the mic and the server")
}

print(String(format: """

[xvc] steady-state mic-to-ear latency over %d frames
  p50 %6.1f ms   p95 %6.1f ms   min %6.1f ms   max %6.1f ms
  drift (last third - first third): %+.1f ms
  jitter buffer: %d underruns, %d overruns, trimmed %.0f ms; settled trough %.0f ms
""", s.count, s.p50 * 1000, s.p95 * 1000, s.min * 1000, s.max * 1000, s.drift * 1000,
     jitter.underruns, jitter.overruns, Double(jitter.trimmedFrames) / 16.0, jitter.learnedTroughMs))

// Split the number so a regression lands in the right place: `wire` should track
// tools/probe_stream.py (~200 ms to the KTH server). Anything above it is ours.
if let t = tapIntervals.summary() {
    print(String(format: "  mic tap interval: p50 %.1f ms / p95 %.1f ms / max %.1f ms",
                 t.p50 * 1000, t.p95 * 1000, t.max * 1000))
}
if let w = tracker.wireSummary(skip: 25) {
    print(String(format: """
      of which capture -> socket: p50 %.1f ms / p95 %.1f ms  (compare tools/probe_stream.py)
      the rest is the jitter buffer + output hardware, i.e. client-side
    """, w.p50 * 1000, w.p95 * 1000))
}

if s.drift * 1000 > 50 {
    print("\n=> LATENCY IS GROWING. The server is falling behind real time. See PERFORMANCE.md §1.")
    exit(1)
} else if s.p95 * 1000 < 500 {
    print(String(format: "\n=> Phase-1 gate PASSED: p95 %.0f ms < 500 ms, drift flat.", s.p95 * 1000))
} else {
    print(String(format: "\n=> p95 %.0f ms exceeds the 500 ms gate.", s.p95 * 1000))
    exit(1)
}
