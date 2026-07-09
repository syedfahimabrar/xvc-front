# Roadmap

Phases are ordered to kill the biggest risks first: GPU throughput (Phase 0) and
end-to-end latency (Phase 1) decide whether the product feels usable — validate them
before investing in driver and UI work. Each phase has an explicit exit gate.

## Phase 0 — GPU benchmark

**Goal:** know, not guess, whether the target GPU keeps up.

- Write `server/bench.py` per `docs/PERFORMANCE.md` §4 (time
  `run_stream_chunk_forward` over a 2.4 s window, p50/p95 after warm-up).
- Run on whatever GPU is available first (the existing KTH box works for a baseline);
  re-run on the dedicated box when provisioned.
- Try tuning levers 1–3 (PERFORMANCE.md §3) and record a small results table in this
  repo.

**Exit gate:** p95 per-window < 100 ms on the chosen GPU + settings.

## Phase 1 — CLI latency prototype (no driver, no UI)

**Goal:** hear the converted voice live on the Mac and measure real mic-to-ear latency.

- Minimal Swift command-line tool (`mac/` — can be an SPM executable):
  mic capture → 16 kHz float32 → `wss://$XVC_HOST:5002/api/meanvc/stream` (existing
  KTH server; self-signed cert override; protocol per `docs/PROTOCOL.md`) → jitter
  buffer → **real speakers** (headphones! — no virtual mic yet).
- Upload a target voice first via `load-target` (can be a curl one-liner initially).
- Print rolling p50/p95 end-to-end latency (PERFORMANCE.md §5).

**Exit gate:** p95 < 500 ms over 2 minutes of continuous speech, no growing drift.
If this fails, fix server tuning/placement — do NOT proceed to Phase 2.

## Phase 2 — Virtual microphone

**Goal:** the converted voice appears as a selectable mic in a real meeting.

- Fork BlackHole → rebrand "XVC Mic" (MAC_APP.md §2), build + codesign, install to
  `/Library/Audio/Plug-Ins/HAL/`, bounce coreaudiod.
- Point the Phase-1 tool's output at the XVC Mic device instead of the speakers.
- Test in a real Zoom and Google Meet call (second account/device on the far end).

**Exit gate:** far-end participant hears the converted voice, quality comparable to a
direct recording; device survives reboot.

## Phase 3 — Dedicated backend

**Goal:** self-contained server this project owns.

- `server/`: trimmed copy of `docs/reference/hearmeout-xvc-server.py` — keep
  `load-target` + `stream`, drop `chat-proxy`/sphn/PersonaPlex; add `XVC_AUTH_TOKEN`
  bearer auth (PROTOCOL.md §3).
- `server/setup.sh` per BACKEND.md §7 (one command on fresh Ubuntu 22.04 + NVIDIA).
- Provision the GPU box (region close to the user — RTT budget in PERFORMANCE.md §2),
  run setup, re-run Phase-0 benchmark there, apply tuning.
- Switch the Mac client to the new server; TLS: Let's Encrypt if hostname, else pinned
  self-signed.

**Exit gate:** Phase-1 latency gate passes against the dedicated server from the
user's normal network.

## Phase 4 — Product polish

**Goal:** one-download install for non-technical users.

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
- Conversion-strength slider (speaker-embedding interpolation) — researched separately
  in the Hear-Me-Out project; port here once the basic pipeline is solid.
- Opus compression of the WS audio (raw float32 @ 16 kHz is only ~512 kbit/s; not worth
  complexity until networks demand it).
