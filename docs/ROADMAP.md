# Roadmap

Phases are ordered to kill the biggest risks first: GPU throughput (Phase 0) and
end-to-end latency (Phase 1) decide whether the product feels usable — validate them
before investing in driver and UI work. Each phase has an explicit exit gate.

## Phase 0 — GPU benchmark ✅ passed 2026-07-09

**Goal:** know, not guess, whether the target GPU keeps up.

**Result:** RTX 3080, p95 34.2 ms per window at defaults — 0.28x load, gate was < 100 ms.
No tuning lever is worth taking (bf16 is a regression; shorter context saves 15% for real
quality risk). Ship `CHUNK_MS=2400`, `CURRENT_MS=120`, fp32. Full table and reasoning in
`docs/BENCHMARKS.md`; the shared-3090 delay is now attributed to contention, not GPU speed.

- Write `server/bench.py` per `docs/PERFORMANCE.md` §4 (time
  `run_stream_chunk_forward` over a 2.4 s window, p50/p95 after warm-up).
- Run on whatever GPU is available first (the existing KTH box works for a baseline);
  re-run on the dedicated box when provisioned.
- Try tuning levers 1–3 (PERFORMANCE.md §3) and record a small results table in this
  repo.

**Exit gate:** p95 per-window < 100 ms on the chosen GPU + settings.

## Phase 1 — CLI latency prototype (no driver, no UI) — built, awaiting speech test

**Goal:** hear the converted voice live on the Mac and measure real mic-to-ear latency.

**Status:** `mac/xvc-cli` is built and passes the gate against the KTH server:
p50 381.9 ms / p95 390.6 ms, drift +1.1 ms over 60 s. Two client bugs found and fixed on
the way (`installTap` ignoring its buffer size; the jitter buffer never draining its prime
overshoot) — both are written up in `docs/BENCHMARKS.md` and `docs/MAC_APP.md` §1.
**Remaining:** run the full 2 minutes with continuous *speech* on headphones and confirm
the converted voice sounds right live. The runs so far measured a silent mic, which
exercises the same timing path but says nothing about audio quality.

The **wire path is already validated** by `tools/probe_stream.py` (a synthetic client
that streams a WAV at real-time pace): p50 199 ms / p95 204 ms, drift −1.2 ms over 120 s
against the KTH server, and the converted audio tracks the target speaker's pitch. So
what remains is the Mac audio I/O, not the protocol. Use the probe as ground truth: if
the Swift client is slower, the extra milliseconds are in capture or the jitter buffer.

- Minimal Swift command-line tool (`mac/` — can be an SPM executable):
  mic capture → 16 kHz float32 → `wss://$XVC_HOST:5002/api/meanvc/stream` (existing
  KTH server; self-signed cert override; protocol per `docs/PROTOCOL.md`) → jitter
  buffer → **real speakers** (headphones! — no virtual mic yet).
- Upload a target voice first via `load-target` (can be a curl one-liner initially).
- Print rolling p50/p95 end-to-end latency (PERFORMANCE.md §5).

**Exit gate:** p95 < 500 ms over 2 minutes of continuous speech, no growing drift.
If this fails, fix server tuning/placement — do NOT proceed to Phase 2.

## Phase 2 — Virtual microphone — driver builds, not yet installed

**Goal:** the converted voice appears as a selectable mic in a real meeting.

**Status: exit gate met in Google Meet** — far end hears the converted voice in a real
call (user-confirmed, 2026-07-11), after fixing a chain of silent client failures: the
engine-sharing input hijack, the rebuild feedback loop, the reused-engine dead mic, the
rebuild-everything stream break, and the missing-notification case (now covered by a
capture watchdog on the input signal itself). See MAC_APP.md §1/§4 and git history.
**FaceTime does not work and will not without driver surgery**: Apple's voice-processing
unit hard-mutes virtual-mic input (measured: exact zeros with no echo reference in play —
MAC_APP.md §2). Same family as WhatsApp not listing the device. Out of scope; the spec
targets apps with their own audio stacks (Meet ✓, Zoom/Teams expected same architecture,
still to be confirmed in a live call).

- Fork BlackHole → rebrand "XVC Mic" (MAC_APP.md §2), build + codesign, install to
  `/Library/Audio/Plug-Ins/HAL/`, bounce coreaudiod.
- Point the Phase-1 tool's output at the XVC Mic device instead of the speakers.
- Test in a real Zoom and Google Meet call (second account/device on the far end).

**Exit gate:** far-end participant hears the converted voice, quality comparable to a
direct recording; device survives reboot.

## Phase 3 — Dedicated backend ✅ exit gate met 2026-07-12

**Goal:** self-contained server this project owns.

**Result:** provisioned a dedicated RTX 3080 box, deployed `server/xvc_server.py` with
bearer-token auth and startup warm-up over self-signed TLS. End to end from the Mac:
**p95 186 ms wire / 373 ms full client**, cold start eliminated (first frame 175 ms, not
2.4 s), zero latency outliers — measurably better than the shared KTH box, confirming its
variance was PersonaPlex contention. Auth verified live (401 without token). Full table in
`docs/BENCHMARKS.md`.

**`CURRENT_MS=60` measured:** cuts full-client latency 373 → 291 ms (−82 ms / 22%), zero
underruns, pitch preserved, GPU still comfortable at ~0.54x. Adopt it pending a listening
A/B (it doubles cross-fade frequency); box currently runs 60 for that check. Default in
`setup.sh` stays 120 until confirmed by ear (docs/BENCHMARKS.md).

**Still open:** reboot survival (no root on this box, so no systemd — running under nohup,
does not survive reboot); real TLS if the box ever gets a hostname.

- `server/`: trimmed copy of `docs/reference/hearmeout-xvc-server.py` — keep
  `load-target` + `stream`, drop `chat-proxy`/sphn/PersonaPlex; add `XVC_AUTH_TOKEN`
  bearer auth (PROTOCOL.md §3).
- **Warm the model at startup** with one dummy `run_stream_chunk_forward` before the
  listener accepts connections. Measured: the first forward of a fresh process costs
  ~2.4 s of lazy CUDA init, so without this the first user hears mangled audio. It is
  per-process, not per-session (`docs/BENCHMARKS.md`).
- `server/setup.sh` per BACKEND.md §7 (one command on fresh Ubuntu 22.04 + NVIDIA).
- Provision the GPU box (region close to the user — RTT budget in PERFORMANCE.md §2),
  run setup, re-run Phase-0 benchmark there, apply tuning.
- Switch the Mac client to the new server; TLS: Let's Encrypt if hostname, else pinned
  self-signed.

**Exit gate:** Phase-1 latency gate passes against the dedicated server from the
user's normal network.

## Phase 4 — Product polish — menu-bar app built, installer pending

**Goal:** one-download install for non-technical users.

**Status:** `mac/XVCLiveMic` is a working menu-bar app (`build-app.sh`). Shares the audio
pipeline with the CLI via the new `XVCCore` library. Has: status-bar mic icon with state
(passthrough/connecting/converting/error), one-click Convert toggle (left-click) with
right-click menu (§3.1), target-voice picker + "Add voice…", Server settings window
(host/token/trust/mic), passthrough when OFF, auto-reconnect with target re-upload, and a
capture level feeding the icon. Launches, renders the status item, captures the mic.
**Remaining:** live end-to-end test through the app UI; the global hotkey; the `.pkg`
installer (app + driver + coreaudiod bounce); Developer ID signing + notarization.

- Menu-bar UI per MAC_APP.md §3 (target picker, toggle, latency readout, failure
  behaviors §4).
- One-click Convert toggle in the system status bar (MAC_APP.md §3.1): left click
  toggles, right click opens the menu, plus a global hotkey for full-screen meetings.
  Cross-faded, no engine restart, passthrough covers the ON pipeline-fill delay.
- Single `.pkg` installer: app + XVC Mic driver + postinstall (coreaudiod bounce).
- Signing + notarization for distribution beyond the team.

**Exit gate:** a fresh Mac with no dev tools: download pkg → install → pick "XVC Mic"
in Zoom → converted conversation works.

## Deliberately out of scope (for now)

- Windows/Linux clients (revisit after macOS proves the concept; Windows needs a
  signed driver — real cost/bureaucracy).
- **On-device inference on Apple Silicon** — measured infeasible 2026-07-11: 13.7x over
  the real-time budget on an M3, and the dominant latency terms (240 ms look-ahead) are
  model properties that local execution does not remove. `docs/BENCHMARKS.md`.
- Conversion-strength slider (speaker-embedding interpolation) — researched separately
  in the Hear-Me-Out project; port here once the basic pipeline is solid.
- Opus compression of the WS audio (raw float32 @ 16 kHz is only ~512 kbit/s; not worth
  complexity until networks demand it).
