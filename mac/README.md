# mac/

The Mac side. No ML here — it only moves audio.

| Target | Phase | What it is |
|---|---|---|
| `xvc-cli` | 1 | headless latency prototype: mic → server → **headphones** |
| `XVCLiveMic` | 4 | SwiftUI menu-bar app — not written yet |
| `XVCMicDriver` | 2 | BlackHole fork, the "XVC Mic" virtual device — not written yet |

## Running the Phase-1 prototype

**Wear headphones.** It plays your converted voice out of the default output device; on
speakers that feeds straight back into the mic.

```bash
export XVC_HOST=<gpu-box-address>     # or pass --host
swift build
.build/debug/xvc-cli --target-wav /path/to/target.wav --insecure --seconds 120
```

The server address is never hardcoded — it comes from `$XVC_HOST` or `--host`, so this
repo can be public without publishing where the GPU box lives.

The first run prompts for microphone access (the prompt is attributed to your terminal,
not to `xvc-cli`). `--insecure` trusts the KTH server's self-signed cert and is scoped to
the host you passed; it is a dev flag and must never reach a shipped build.

Useful flags: `--trough-ms` (jitter buffer depth to converge on, default 40),
`--prime-ms` (depth before playback starts, default 180), `--host`, `--target-id`.
`XVC_DEBUG_TAP=1` prints capture granularity and device buffer size.

## Reading the output

```
[xvc] steady-state mic-to-ear latency over 483 frames
  p50  381.9 ms   p95  390.6 ms   min  355.4 ms   max  481.1 ms
  drift (last third - first third): +1.1 ms
  jitter buffer: 1 underruns, 0 overruns, trimmed 197 ms of standing latency
  of which capture -> socket: p50 226.1 ms / p95 244.4 ms
```

The gate is **p95 < 500 ms with flat drift** over 2 minutes of continuous speech. Rising
drift is the failure in `PERFORMANCE.md` §1 — the server falling behind on every window,
so delay grows for as long as you talk.

`capture -> socket` is the same measurement `tools/probe_stream.py` reports (~210 ms to
KTH). Compare them: if `xvc-cli`'s wire number is much worse, the fault is in this client,
not the network or the GPU. That split is how the two big client bugs below were found.

## Two things that will bite you

**Capture uses `AVAudioSinkNode`, not `installTap`.** `installTap` ignores its `bufferSize`
on macOS and hands over 100 ms buffers regardless, which becomes a 100 ms latency tail.
See `docs/BENCHMARKS.md`.

**The jitter buffer shrinks itself.** Priming overshoots because bursts are indivisible, and
the excess would otherwise be permanent latency. `JitterBuffer` watches the low-water mark
and splices out unused depth with a cross-fade.

## Layout

```
Sources/xvc-cli/
  main.swift           # arg parsing, orchestration, reporting
  AudioIO.swift        # capture (sink node), resample, playout (source node)
  JitterBuffer.swift   # ring buffer, priming, adaptive shrink
  XVCClient.swift      # load-target upload, WebSocket, TLS override
  LatencyTracker.swift # sample-count bookkeeping (PERFORMANCE.md §5)
```
