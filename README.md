# XVC Live Mic

Real-time voice conversion for **any** meeting platform (Zoom, Google Meet, Teams, Discord, …)
via a **universal virtual microphone** on macOS — no per-platform plugins.

The X-VC voice-conversion model runs on a **remote GPU server**; a lightweight native
**Swift menu-bar app** on the Mac moves audio between the real mic, the server, and a
virtual microphone that every meeting app can select like a normal mic.

## Architecture

```
┌─────────────────────────── Mac laptop ───────────────────────────┐
│                                                                  │
│  real mic ──► Swift app ──[wss: float32 PCM 16 kHz]──────────────┼──► GPU server
│                  ▲                                               │    (X-VC, port 5002)
│                  └──[wss: converted float32 PCM 16 kHz]──────────┼──◄─┘
│                  │                                               │
│                  ▼                                               │
│           "XVC Mic" virtual device (bundled BlackHole fork)      │
│                  │                                               │
│                  ▼                                               │
│        Zoom / Meet / Teams pick "XVC Mic" as their microphone    │
└──────────────────────────────────────────────────────────────────┘
```

Why this design (decisions already made — see `PROJECT.md`):
- **Virtual mic = universal input.** Every meeting app already has a mic picker; one
  virtual device covers all of them. No plugins.
- **GPU stays remote.** X-VC needs a CUDA GPU (~20× realtime compute); the Mac only
  shuffles audio (trivial CPU load).
- **Native Swift.** One-download `.app`, lowest latency, no runtime dependencies.
- **Bundled driver.** The virtual mic is a rebranded fork of BlackHole (MIT); it ships
  inside our installer, so the user installs exactly one thing.

## Components

| Component | Where | Status |
|---|---|---|
| X-VC streaming server (trimmed: `load-target` + `stream` + auth) | remote GPU box | to build — reference impl in `docs/reference/` |
| Swift menu-bar app (capture → WS → jitter buffer → virtual mic) | Mac | to build |
| "XVC Mic" virtual audio driver (BlackHole fork) | Mac, bundled in installer | to build |
| GPU benchmark script (per-window forward time) | remote GPU box | to build first (Phase 0) |

## Documentation

- `PROJECT.md` — project brief + locked decisions for agent sessions
- `docs/PROTOCOL.md` — exact wire protocol (verified against the working Hear-Me-Out server)
- `docs/BACKEND.md` — everything needed to stand up the GPU server (repo, commit, models, pins, env)
- `docs/PERFORMANCE.md` — latency budget, why a 3090 struggles, tuning levers
- `docs/MAC_APP.md` — Swift app + virtual-mic driver design
- `docs/ROADMAP.md` — phased build order
- `docs/reference/hearmeout-xvc-server.py` — proven streaming server this project derives from

## Roadmap (summary)

0. **Benchmark** the GPU: per-window forward time decides everything else.
1. **CLI prototype**: mic → existing KTH server → speakers; measure real end-to-end latency.
2. **Virtual mic**: build the rebranded driver, route converted audio into it, verify in Zoom/Meet.
3. **Dedicated backend**: trimmed server + one-command setup + auth + TLS on the new GPU box.
4. **Product**: menu-bar UI + single `.pkg` installer (app + driver).

Full detail in `docs/ROADMAP.md`.

## Origin

Spun out of the Hear-Me-Out research project (KTH). The wire protocol and streaming
window math are lifted verbatim from its battle-tested X-VC service, so Phase 1 can be
tested against the existing server at `$XVC_HOST:5002` before any new backend exists.
