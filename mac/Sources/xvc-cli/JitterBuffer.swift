import Foundation

/// Ring buffer between the WebSocket (bursty: the server emits 120 ms at a time) and the
/// audio render callback (steady: it wants a few hundred frames every few milliseconds).
///
/// Priming is the whole point. If we start playing the instant the first burst lands, the
/// next render callback almost certainly runs before the second burst arrives, and we
/// glitch. So we wait until `primeFrames` are buffered, then play. On underrun we emit
/// silence and re-prime rather than stuttering, per docs/MAC_APP.md §1.
///
/// `render` is called on the realtime audio thread. NSLock is not strictly realtime-safe
/// (it can block if the writer holds it), but the writer's critical section is a memcpy of
/// at most 1920 frames, and this is a measurement prototype. A production build should use
/// a single-producer/single-consumer lock-free ring.
final class JitterBuffer {
    private var storage: [Float]
    private var readIndex = 0
    private var count = 0
    private let lock = NSLock()

    private let primeFrames: Int
    private var primed = false

    private(set) var underruns = 0
    private(set) var overruns = 0

    // --- adaptive shrink (docs/MAC_APP.md §1) ---
    //
    // Priming overshoots. We wait for `primeFrames`, but audio arrives in indivisible
    // 1920-frame bursts, so we cross the threshold mid-burst and begin playback holding
    // more than we asked for. Nothing drains it — input and output both run at 16 kHz —
    // so the excess becomes permanent latency whose size is decided by luck. Measured:
    // p50 swung 417-511 ms across runs with identical settings.
    //
    // Fix: watch the buffer's low-water mark across a review window. Depth that survives a
    // whole window is standing latency, not jitter headroom, so discard it. Discarding
    // mid-speech would click, so splice with a short cross-fade, and rate-limit so the
    // resulting time compression (~2%) is inaudible.
    // The trough cannot be a constant. Measured against real speech, a fixed 40 ms trough
    // trims to exactly 40 ms and parks there — but arrival jitter is ~28 ms (wire p50 231 /
    // p95 259), so it underruns, re-primes, gets trimmed back down, and underruns again.
    // So grow the target on every underrun: the buffer discovers the jitter it actually has
    // to absorb. Standard adaptive-jitter-buffer behaviour, and it self-tunes per network.
    private var targetTroughFrames: Int
    private let troughGrowthFrames = 320     // +20 ms per underrun
    private let troughCeilingFrames = 2560   // 160 ms; past this something else is wrong
    private var lowWater = Int.max
    private var framesSinceReview = 0
    private var framesSinceSplice = 0
    private var pendingDrop = 0
    private(set) var trimmedFrames = 0

    private let reviewInterval = 8000        // 0.5 s at 16 kHz
    private let spliceDropMax = 160          // 10 ms per splice: 2% time compression
    private let silentDropMax = 480          // 30 ms when it's inaudible anyway
    private let fadeFrames = 64              // 4 ms cross-fade across the splice
    private let silenceThreshold: Float = 0.005

    var bufferedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// The floor the buffer has settled on, in ms. Starts at the configured trough and
    /// grows each time it underruns, so it converges on the jitter this path actually has.
    var learnedTroughMs: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(targetTroughFrames) / 16.0
    }

    /// - Parameters:
    ///   - primeFrames: how much to buffer before playback starts. One server burst is
    ///     1920 frames (120 ms); 1.5 bursts absorbs one late burst without a gap.
    ///   - targetTroughFrames: the depth the buffer should fall to just before each burst
    ///     lands — a *starting guess only*. Every underrun raises it by 20 ms, so the
    ///     buffer converges on however much jitter this network and server actually impose.
    init(capacityFrames: Int = 16000 * 2, primeFrames: Int = 2880, targetTroughFrames: Int = 640) {
        self.storage = [Float](repeating: 0, count: capacityFrames)
        self.primeFrames = primeFrames
        self.targetTroughFrames = targetTroughFrames
    }

    func write(_ pcm: [Float]) {
        lock.lock(); defer { lock.unlock() }
        let capacity = storage.count
        if pcm.count > capacity { return }

        // Overrun: the consumer stalled (device change, sleep). Drop the oldest audio —
        // keeping it would only add permanent latency.
        if count + pcm.count > capacity {
            let drop = count + pcm.count - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
            overruns += 1
        }

        var w = (readIndex + count) % capacity
        for sample in pcm {
            storage[w] = sample
            w = (w + 1) % capacity
        }
        count += pcm.count
    }

    /// Fills `frames` samples. Called from the realtime render callback.
    func render(into ptr: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }

        if !primed {
            if count >= primeFrames {
                primed = true
                lowWater = count
                framesSinceReview = 0
            } else {
                ptr.update(repeating: 0, count: frames)
                return
            }
        }

        shrinkIfStanding(renderFrames: frames)

        let capacity = storage.count
        let available = min(frames, count)
        for i in 0..<available {
            ptr[i] = storage[(readIndex + i) % capacity]
        }
        readIndex = (readIndex + available) % capacity
        count -= available

        if available < frames {
            // Ran dry mid-callback: pad with silence and re-prime before playing again.
            ptr.advanced(by: available).update(repeating: 0, count: frames - available)
            underruns += 1
            primed = false
            pendingDrop = 0   // we just lost depth; do not also trim it away

            // We ran dry, so the floor is higher than we believed. Raise it, or we will
            // trim straight back down and underrun again on the next late burst.
            targetTroughFrames = min(targetTroughFrames + troughGrowthFrames, troughCeilingFrames)
        }
    }

    // MARK: - shrink

    /// Caller holds the lock.
    private func shrinkIfStanding(renderFrames: Int) {
        lowWater = min(lowWater, count)
        framesSinceReview += renderFrames
        framesSinceSplice += renderFrames

        if framesSinceReview >= reviewInterval {
            // Whatever the buffer never fell below is depth we are simply carrying.
            if lowWater > targetTroughFrames {
                pendingDrop = max(pendingDrop, lowWater - targetTroughFrames)
            }
            lowWater = count
            framesSinceReview = 0
        }

        guard pendingDrop > 0 else { return }
        let headroom = count - targetTroughFrames - renderFrames - fadeFrames
        guard headroom > 0 else { return }

        // Silence is free to discard, and real speech supplies it constantly.
        let silentDrop = min(pendingDrop, silentDropMax, headroom)
        if silentDrop > 0 && isSilent(silentDrop) {
            readIndex = (readIndex + silentDrop) % storage.count
            count -= silentDrop
            pendingDrop -= silentDrop
            trimmedFrames += silentDrop
            return
        }

        // Otherwise splice, but no more than once per review window.
        guard framesSinceSplice >= reviewInterval else { return }
        let drop = min(pendingDrop, spliceDropMax, headroom)
        guard drop > 0 else { return }
        spliceOut(drop)
        pendingDrop -= drop
        trimmedFrames += drop
        framesSinceSplice = 0
    }

    /// True if the next `n` buffered frames are quiet enough to discard inaudibly.
    private func isSilent(_ n: Int) -> Bool {
        let capacity = storage.count
        for i in 0..<n where abs(storage[(readIndex + i) % capacity]) > silenceThreshold {
            return false
        }
        return true
    }

    /// Remove `drop` frames at the read cursor without a discontinuity: cross-fade the
    /// audio we are about to skip into the audio that follows it, so the sample after the
    /// last one already played still lines up.
    private func spliceOut(_ drop: Int) {
        let capacity = storage.count
        for i in 0..<fadeFrames {
            let w = Float(i) / Float(fadeFrames)
            let skipped = storage[(readIndex + i) % capacity]
            let kept = storage[(readIndex + drop + i) % capacity]
            storage[(readIndex + drop + i) % capacity] = skipped * (1 - w) + kept * w
        }
        readIndex = (readIndex + drop) % capacity
        count -= drop
    }
}
