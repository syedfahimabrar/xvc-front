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

## KTH shared box ($XVC_HOST, RTX 3090)

Baseline for comparison — this GPU is shared with the PersonaPlex dialogue model,
which is one suspected cause of the "struggles with some delay" symptom
(`docs/PERFORMANCE.md` §1). Run the sweep here first; it costs nothing and tells us
whether contention or raw GPU speed is the problem.

_Not yet measured._

## Dedicated box (Phase 3)

_Not yet provisioned. Re-run the sweep here after `setup.sh` and pick final settings._
