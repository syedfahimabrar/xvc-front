import AVFoundation
import Foundation

/// Mic-to-ear latency by sample-count bookkeeping (the README).
///
/// The stream has no frame IDs, but output sample k corresponds to input sample k: the
/// server emits each window's "current" region in order. So we remember when each sent
/// chunk was *captured*, and when output sample k arrives we look up the capture time of
/// input sample k. This is the same accounting tools/probe_stream.py uses, which is what
/// makes the two comparable.
///
/// What "now" means matters. Arrival at the socket is not arrival at the ear: the audio
/// still has to clear the jitter buffer and the output hardware. So callers pass that
/// residual in as `pendingPlayout`, and we report the sum.
public final class LatencyTracker {
    public init() {}
    private struct SentChunk {
        let endSample: Int      // cumulative input sample index, exclusive
        let capturedAt: Double  // seconds, mach timebase
    }

    private var sent: [SentChunk] = []
    private var cursor = 0          // first chunk not yet matched to output
    private var inputSamples = 0
    private var outputSamples = 0
    private var latencies: [Double] = []   // to the ear
    private var wireLatencies: [Double] = []  // to the socket — comparable to probe_stream.py
    private let lock = NSLock()

    public private(set) var lastLatency: Double = 0

    public func recordSend(frames: Int, capturedAt: Double) {
        lock.lock(); defer { lock.unlock() }
        inputSamples += frames
        sent.append(SentChunk(endSample: inputSamples, capturedAt: capturedAt))
    }

    /// - Parameter pendingPlayout: seconds of audio still ahead of this sample before it
    ///   reaches the ear (jitter-buffer depth + output hardware latency).
    @discardableResult
    public func recordReceive(frames: Int, now: Double, pendingPlayout: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        outputSamples += frames

        // Find the chunk containing input sample (outputSamples - 1).
        while cursor < sent.count && sent[cursor].endSample < outputSamples { cursor += 1 }
        guard cursor < sent.count else { return nil }   // output ran ahead of input: impossible, but don't crash

        let wire = now - sent[cursor].capturedAt
        let latency = wire + pendingPlayout
        wireLatencies.append(wire)
        latencies.append(latency)
        lastLatency = latency

        // Chunks before the cursor can never match again.
        if cursor > 512 {
            sent.removeFirst(cursor)
            cursor = 0
        }
        return latency
    }

    /// p50/p95 over the most recent `window` measurements (rolling, as the gate requires).
    public func rolling(window: Int = 250) -> (p50: Double, p95: Double, count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard !latencies.isEmpty else { return nil }
        let recent = Array(latencies.suffix(window)).sorted()
        return (percentile(recent, 0.50), percentile(recent, 0.95), latencies.count)
    }

    /// Overall stats plus drift: median of the last third minus the first third. A rising
    /// number is the failure mode from the README — the server falling behind a
    /// little on every window, so delay grows for as long as someone talks.
    public func summary(skip: Int = 0) -> (p50: Double, p95: Double, min: Double, max: Double, drift: Double, count: Int)? {
        lock.lock(); defer { lock.unlock() }
        let usable = latencies.count > skip ? Array(latencies.dropFirst(skip)) : []
        guard usable.count >= 10 else { return nil }
        let sorted = usable.sorted()
        let third = max(1, usable.count / 3)
        let firstThird = Array(usable.prefix(third)).sorted()
        let lastThird = Array(usable.suffix(third)).sorted()
        let drift = percentile(lastThird, 0.5) - percentile(firstThird, 0.5)
        return (percentile(sorted, 0.50), percentile(sorted, 0.95), sorted.first!, sorted.last!, drift, usable.count)
    }

    /// Capture-to-socket only, excluding the jitter buffer and output hardware. This is the
    /// number tools/probe_stream.py reports, so a gap between them is client-side.
    public func wireSummary(skip: Int = 0) -> (p50: Double, p95: Double)? {
        lock.lock(); defer { lock.unlock() }
        let usable = wireLatencies.count > skip ? Array(wireLatencies.dropFirst(skip)) : []
        guard usable.count >= 10 else { return nil }
        let sorted = usable.sorted()
        return (percentile(sorted, 0.50), percentile(sorted, 0.95))
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }
}

/// Seconds on the same mach timebase the audio engine timestamps buffers with.
public func machNow() -> Double {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
}

/// Diagnostic: the wall-clock gap between successive mic tap callbacks. If the tap is
/// ragged, the server receives input in clumps and emits output in clumps, which shows up
/// as a latency tail no amount of client-side buffering can remove.
public final class TapIntervals {
    public init() {}
    private var last: Double = 0
    private var gaps: [Double] = []
    private let lock = NSLock()

    public func mark(_ now: Double) {
        lock.lock(); defer { lock.unlock() }
        if last > 0 { gaps.append(now - last) }
        last = now
    }

    public func summary() -> (p50: Double, p95: Double, max: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard gaps.count >= 10 else { return nil }
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double { sorted[Int((Double(sorted.count - 1) * p).rounded())] }
        return (pct(0.5), pct(0.95), sorted.last!)
    }
}
