# mac/

The Mac side. No ML here — it only moves audio.

| Target | Phase | What it is |
|---|---|---|
| `xvc-cli` | 1 | headless latency prototype: mic → server → **headphones** |
| `driver/` | 2 | build script for the "XVC Mic" virtual device (rebranded BlackHole) |
| `XVCLiveMic` | 4 | the menu-bar app (`build-app.sh`) |
| `XVCCore` | — | shared audio pipeline used by both the CLI and the app |

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

## The menu-bar app (Phase 4)

```bash
cd mac
./build-app.sh run          # build build/"XVC Live Mic.app" and launch it
```

A menu-bar-only app (no Dock icon). The mic icon shows state: outline = passthrough
(your real voice), filled+accent = converting, triangle = error. **Left-click toggles
Convert; right-click opens the menu** (target picker, Server settings, quit) — the toggle
must be one click mid-call (docs/MAC_APP.md §3.1).

First run: click the icon → **Server settings** (host, port, token, "trust self-signed"),
then **Add voice…** (pick a target WAV). Then left-click to Convert ON. In the meeting app,
select **XVC Mic** as the microphone. Convert OFF passes your real voice through to XVC Mic
so you never have to switch devices mid-call.

Ad-hoc signed; macOS will prompt for microphone access on first capture. Distribution
(Developer ID + notarization + `.pkg` installer bundling the driver) is the remaining
Phase-4 work.

## The XVC Mic virtual device (Phase 2)

```bash
cd driver
./build.sh              # clones BlackHole at a pinned tag, rebrands, verifies
./build.sh install      # copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
./build.sh uninstall
```

Installing needs your password and briefly interrupts all audio on the machine — a HAL
plug-in lives in a root-owned directory and CoreAudio only rescans on restart. Every audio
product does this (Krisp, Loopback, VB-Cable).

Then render the converted voice into it instead of the speakers:

```bash
.build/debug/xvc-cli --target-wav t.wav --insecure --output-device "XVC Mic"
xvc-cli --list-devices     # see what this Mac has
```

Whatever is rendered to the device's output side appears at its input side, so Zoom, Meet
and Teams see "XVC Mic" as an ordinary microphone.

`build.sh` verifies the rebrand by inspecting the built binary, because a mis-quoted build
flag produces a working driver with the *wrong device name* and no error. See
`docs/MAC_APP.md` §2.

## Layout

```
Sources/xvc-cli/
  main.swift           # arg parsing, orchestration, reporting
  AudioIO.swift        # capture (sink node), resample, playout (source node)
  JitterBuffer.swift   # ring buffer, priming, adaptive shrink
  XVCClient.swift      # load-target upload, WebSocket, TLS override
  LatencyTracker.swift # sample-count bookkeeping (PERFORMANCE.md §5)
  AudioDevices.swift   # enumerate/select CoreAudio devices by name
Sources/XVCCore/       # ^ the above five, shared as a library
Sources/XVCLiveMic/    # the menu-bar app
  main.swift           # LSUIElement app entry
  Engine.swift         # passthrough <-> converting, connection lifecycle, reconnect
  StatusItemController.swift  # menu-bar item: left-click toggle, right-click menu
  SettingsWindow.swift # server + mic settings (SwiftUI)
  AppSettings.swift    # persisted config (UserDefaults)
build-app.sh           # assemble + sign the .app bundle
driver/
  build.sh             # clone + rebrand + verify + install the virtual device
  xvcmic_names.h       # the rebrand constants, injected with clang -include
```
