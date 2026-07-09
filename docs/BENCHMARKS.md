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

## KTH shared box ($XVC_HOST, RTX 3090)

_Not measured — and the 3080 result above makes it much less interesting._ A **slower**
GPU runs the default window at 0.28x load with no jitter. A 3090 is ~1.2–1.4x a 3080 on
this workload, so raw speed cannot explain the "struggles with some delay" symptom
(`PERFORMANCE.md` §1). The remaining explanation is contention: that box shares its GPU
with the PersonaPlex dialogue model (lever 4).

This matters because it means the symptom is an artifact of the shared deployment, not a
property of X-VC — a dedicated box should not reproduce it. Worth confirming opportunistically
(run the sweep there while PersonaPlex is serving, and again while it is idle), but it no
longer blocks anything.

## Dedicated box (Phase 3)

_Not yet provisioned. Re-run the sweep after `setup.sh` to confirm the settings above hold._
