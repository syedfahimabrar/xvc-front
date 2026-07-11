# Benchmark results

Measured per-window forward times from `server/bench.py`. One section per GPU. Fill
these in from real runs only — the whole point of Phase 0 is to stop guessing.

**Gate:** p95 per-window < 100 ms. **Governing metric:** load = p95 / `CURRENT_MS`
(share of real time the GPU is busy; > 1.0 means delay grows while the user talks).

How to read the columns: per-window cost depends on `CHUNK_MS` only, so each row is
one measurement and the two load columns are that row's p95 divided by each candidate
`CURRENT_MS`. See `docs/PERFORMANCE.md` §§1–4.

## Template

```
### <GPU name> — <shared or dedicated>, <date>
torch <ver> / CUDA <ver>, tf32 <on|off>, 50 iters after 5 warm-ups
Command: python bench.py --sweep --tf32

| chunk_ms | dtype | p50 ms | p95 ms | peak VRAM | load @ 120 ms | load @ 240 ms | verdict |
|----------|-------|--------|--------|-----------|---------------|---------------|---------|

Quality check (levers 2/3): <listened to --dump-wav? verdict>
Conclusion: <settings chosen, and why>
```

## RTX 3080 — idle box, 2026-07-09

torch 2.5.1+cu121 / CUDA 12.1, tf32 on, 50 iters after 5 warm-ups.
Command: `python bench.py --sweep --tf32`

| chunk_ms | dtype | p50 ms | p95 ms | peak VRAM | load @ 120 ms | load @ 240 ms | verdict |
|----------|-------|--------|--------|-----------|---------------|---------------|-------------|
| 2400     | fp32  | 33.1   | 34.2   | 2.5 GB    | 0.28x         | 0.14x         | comfortable |
| 2400     | bf16  | 34.3   | 35.9   | 2.7 GB    | 0.30x         | 0.15x         | comfortable |
| 1600     | fp32  | 28.7   | 29.0   | 2.4 GB    | 0.24x         | 0.12x         | comfortable |
| 1600     | bf16  | 32.6   | 32.8   | 2.7 GB    | 0.27x         | 0.14x         | comfortable |

**Conclusion: ship the defaults** (`CHUNK_MS=2400`, `CURRENT_MS=120`, fp32). The gate is
p95 < 100 ms; we are at 34.2 ms, a 0.28x load fraction. Neither quality-risking lever is
worth taking:

- **Lever 3 (fp16/bf16) is a regression here**, not a speedup: bf16 costs ~1 ms more at
  both context sizes. The forward is small enough to be launch- and memory-bound, so
  autocast's cast overhead exceeds any tensor-core gain. Do not enable it.
- **Lever 2 (shorter `CHUNK_MS`) saves only 15%**, not the ~33% a cost-scales-with-length
  model predicts — again because fixed overhead dominates. Not worth the quality risk for
  5 ms.
- **Lever 1 (`CURRENT_MS` 240) is unnecessary.** It would halve a load we already have in
  surplus while adding +120 ms of latency — the wrong trade at 0.28x.

**p95 ≈ p50 (34.2 vs 33.1)**: a tight distribution, meaning no GPU contention and no
thermal throttling on this box. Contrast with the KTH 3090 below — that is the whole
finding.

Peak VRAM is `torch.cuda.max_memory_allocated` (weights + activations); it excludes the
caching allocator's reserved pool and the ~0.5 GB CUDA context. Real usage is ~3 GB, well
under `PERFORMANCE.md` §1's 6–8 GB estimate and nowhere near a constraint.

Caveat: run with a synthetic target and noise source. Timing is data-independent (the
model has fixed shapes and no early exits, which the near-zero p95−p50 spread supports),
but this run says nothing about audio quality.

## KTH shared box (shared RTX 3090)

_Not measured — and the 3080 result above makes it much less interesting._ A **slower**
GPU runs the default window at 0.28x load with no jitter. A 3090 is ~1.2–1.4x a 3080 on
this workload, so raw speed cannot explain the "struggles with some delay" symptom
(`PERFORMANCE.md` §1). The remaining explanation is contention: that box shares its GPU
with the PersonaPlex dialogue model (lever 4).

This matters because it means the symptom is an artifact of the shared deployment, not a
property of X-VC — a dedicated box should not reproduce it. Worth confirming opportunistically
(run the sweep there while PersonaPlex is serving, and again while it is idle), but it no
longer blocks anything.

## Apple Silicon — can the model run on the Mac itself? Measured: no.

M3 (base, MacBook Air, 16 GB), torch 2.5.1 MPS + `PYTORCH_ENABLE_MPS_FALLBACK=1`,
20 iters after 5 warm-ups, defaults (`CHUNK_MS=2400`). `tools/mps_bench.py`, 2026-07-11.

| device | p50 | p95 | budget | load | memory |
|---|---|---|---|---|---|
| RTX 3080 (reference) | 33.1 ms | 34.2 ms | <120 ms | 0.28x | 2.5 GB |
| **M3 MPS** | **1227.6 ms** | **1644.3 ms** | <120 ms | **13.7x** | 2.26 GB |

**Memory is not the constraint** (2.26 GB of 16 GB unified — any M-series Mac holds it).
Compute is: the M3 needs ~1.3 s to emit each 120 ms window, so delay grows ~12 s per
second of speech. No window tuning bridges 13.7x, and lever 1's ceiling is 2x. A top
M4 Max (~4x the base M3 GPU) would still land ~3x over budget.

Honest caveats: MPS fallback may push some ops to CPU, and a real port (MLX/Core ML,
fp16, fused kernels) could plausibly buy 2–5x — still short of 14x, and that is a
research project, not packaging. Model load on M3: 31.7 s; `load-target` equivalent:
5.3 s (vs 0.9 s server-side). Shipping would also mean a ~6 GB download per user
(xvc.pt 4.66 GB + GLM tokenizer 1.36 GB) with weight licensing unexamined.

Local inference also would NOT deliver "much lower latency": of the measured ~400 ms,
only ~6 ms is network and ~160 ms jitter buffer (removable locally); the 240 ms
algorithmic look-ahead is a property of the model on any hardware. Local best case
≈ 250–300 ms — and only if compute fit the budget, which it does not.

**Consequence: the "X-VC never runs on the Mac" architecture decision is now backed by
measurement, not assumption.** Revisit only if the model family changes.

## Dedicated box (Phase 3)

_Not yet provisioned. Re-run the sweep after `setup.sh` to confirm the settings above hold._

---

# End-to-end over the wire

`tools/probe_stream.py`, Mac → KTH server (RTX 3090, shared), 20 ms send chunks.

## 2026-07-09 — 120 s continuous speech, KTH from campus network

RTT to the KTH box: **5.6 ms** avg (4.0 min / 9.8 max, 0% loss). `load-target` on an
8 s WAV: 0.9 s.

| Metric | Value |
|---|---|
| p50 latency | 198.8 ms |
| p95 latency | 204.4 ms |
| min / max | 179.8 / 524.9 ms |
| drift (last third − first third) | **−1.2 ms** |
| audio in → out | 120.0 s → 119.9 s |

**Phase-1 gate passed on the network path** (p95 < 500 ms, drift flat). The p95−p50 gap
is 6 ms: the server tracks real time rather than slowly falling behind, which is the
failure mode `PERFORMANCE.md` §1 warns about. Note this measures the *wire*; the Swift
client adds mic capture and jitter buffer on top.

The budget closes arithmetically, which is the real reason to trust the number:
120 ms look-ahead (see below) + 34 ms GPU + ~6 ms RTT ≈ 160 ms floor, and the observed
minimum is 179.8 ms.

**Latency is measured at each frame's last sample**, which waits only
`smooth + future` = 120 ms of look-ahead. The frame's *first* sample waits the full
240 ms. So perceived latency spans roughly [p50, p50 + 120] ms — call it 200–320 ms
here, before the client's jitter buffer.

**One outlier at 524.9 ms** in 976 frames (p95 is 204 ms, so this is a lone spike, most
likely contention from the dialogue model sharing that GPU). A frame arriving ~320 ms
late will underrun a 240 ms jitter buffer. Once per two minutes is survivable — emit
silence and re-prime (`MAC_APP.md` §1) rather than growing the buffer for everyone.

## Cold start is per-process, not per-session

The **first ever** forward after the server process loads costs ~2.4 s (lazy CUDA/cuDNN
init — the thing `bench.py`'s warm-ups exclude). First frame of that session: 2462 ms.

A second WebSocket session against the same warm process showed **no cold start** (first
frame 236 ms, in line with steady state). So this is not paid per connection, and the
menu-bar toggle does not expose it.

**Consequence for Phase 3:** the server must run one dummy forward at startup, before
accepting connections. Otherwise the first user of a freshly started server hears ~2.4 s
of mangled audio.

---

# Swift client — mic to ear (`mac/xvc-cli`)

2026-07-09, MacBook mic (48 kHz, 512-frame device buffer) → KTH server → headphones.
Runs below used a silent mic; latency accounting is independent of what is spoken.

| Run | p50 | p95 | drift | underruns |
|---|---|---|---|---|
| 2 min, real speech, fixed 40 ms trough | 381.4 ms | 465.7 ms | +3.4 ms | 7 |
| **60 s, adaptive trough (defaults)** | **406 ms** | **442 ms** | +1.1 ms | 1 |

Gate is p95 < 500 ms with flat drift; both pass. The budget closes: 230 ms wire + 220 ms
buffer (one 120 ms burst + 100 ms settled trough) + 1.5 ms output hardware ≈ 450 ms.

The 2-minute run was played on **speakers, not headphones**, so the mic re-captured the
converted output and the server converted its own voice. Latency accounting is content-
independent, so those numbers stand; audio quality was not assessed. Use `--mute` to
measure latency without headphones.

## The two client-side bugs worth remembering

**`installTap` ignores its `bufferSize`.** Measured, it delivered 4800-frame (100 ms)
buffers whether we asked for 256, 512, 1024 or 2048 — while the device was running
512-frame buffers. The server then received input in clumps, completed windows in clumps,
and returned a ~100 ms latency tail. Visible as wire p95 307 ms against the probe's 204 ms
on the same path in the same minute, with p50 identical (207 vs 209). Chunk *size* never
mattered; chunk *regularity* did. Switching to `AVAudioSinkNode` gave device granularity
(512 frames, 10.7 ms) and collapsed the wire spread from 100 ms to 6 ms.

| capture | wire p50 | wire p95 | spread |
|---|---|---|---|
| `installTap` | 207.6 ms | 307.7 ms | 100 ms |
| `AVAudioSinkNode` | 226.1 ms | 244.4 ms | 18 ms |
| `probe_stream.py` (reference) | 208.8 ms | 213.2 ms | 4 ms |

**Jitter buffer depth is decided by luck unless it shrinks.** Priming waits for 2880
frames, but bursts are indivisible 1920-frame lumps, so playback begins holding ~3840
(240 ms). Nothing drains it — both ends run at 16 kHz — so it is permanent latency. p50
wandered 417–511 ms across identical runs. Fix: watch the low-water mark and splice out
depth that is never used, cross-fading 4 ms so it doesn't click.

**But the trough it converges to cannot be a constant.** A fixed 40 ms trough looked
optimal over 18 s runs (p95 387.8 ms, no underruns) and then produced **7 underruns in a
2-minute run**: the shrink drives depth to exactly the trough and parks there, with no
margin for the ~28 ms of arrival jitter (wire p50 231 / p95 259). Each underrun re-primes,
the shrink trims it back down, and it underruns again.

So the trough grows 20 ms on every underrun, and the buffer discovers its own floor:

| starting trough | settles at | p50 | p95 | underruns / 45-60 s |
|---|---|---|---|---|
| 40 ms | 100 ms | — | 443 ms | 3 |
| **80 ms** | **100 ms** | **406 ms** | **442 ms** | **1** |
| 100 ms | 120 ms | 408.6 ms | 461.9 ms | 1 |

100 ms is this path's real floor — 2.5x the 40 ms that short runs suggested. Starting at
80 ms reaches it with one underrun; starting higher just settles higher. The cost over the
(unsafe) fixed 40 ms trough is ~25 ms of latency, in exchange for not clicking every 20 s.

Lesson worth keeping: **short runs cannot measure a jitter floor.** The failure only
appears once the shrink has had time to reach the trough.

## Where the remaining latency lives

Of 382 ms, roughly 120 ms is algorithmic look-ahead, 34 ms is GPU, ~6 ms is network, and
160 ms is the jitter buffer — of which **120 ms is one server burst**. The buffer cannot go
below one burst, because that is the granularity output arrives in.

So the next real lever is **`CURRENT_MS` on the server**, and it points *down*, not up.
`PERFORMANCE.md` §3 only considers raising it (120 → 240) to cut GPU load. But Phase 0
measured a 0.28x load fraction: dropping `CURRENT_MS` to 60 would put load at ~0.57x —
still inside "comfortable" — while halving both the look-ahead *and* the burst the client
must buffer. Estimated saving ~120 ms end to end. Untested (the KTH server's config is
fixed and shared); test it on the dedicated box in Phase 3, and listen, since it changes
the cross-fade cadence.

## Does it actually sound like the target?

Autocorrelation pitch, as an objective check (not a substitute for listening). Two runs,
in opposite pitch directions, so the result can't be an artifact of the model drifting
one way:

| Run | source | target | converted |
|---|---|---|---|
| synthetic (`say` Daniel → Samantha) | 112.7 Hz | 177.8 Hz | **170.2 Hz** |
| real voices (35.8 s recording → `Target_2.wav`) | 156.9 Hz | 109.4 Hz | **106.7 Hz** |

The output tracks the target speaker in both directions. Real-voice run latency was
unchanged: p50 197.0 ms, p95 203.0 ms, drift +0.8 ms.

## Output sits near full scale — do not apply makeup gain

X-VC normalizes loudness toward the target. The real-voice source peaked at 0.275 (a
quiet recording); the **converted output peaked at 0.985** — 0.13 dB of headroom, from an
input 11 dB below it.

Nothing clipped (0 samples at the int16 ceiling; 7 of 570k above 0.9; crest factor
26.4 dB, normal for speech). But the margin is thin enough that any client-side gain
would clip, and a quiet mic makes adding gain tempting. Don't. If protection is wanted,
use a soft limiter on the playout path, never a fixed boost.
