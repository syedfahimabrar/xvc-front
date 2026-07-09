# Mac App — Swift menu-bar client + "XVC Mic" virtual device

Native Swift (SwiftUI menu-bar app). The Mac side does **no ML** — it only moves audio.
Load is a few percent of one core; any Mac from the last decade suffices.

## 1. Audio pipeline

```
AVAudioEngine input tap (real mic, device rate, mono)
  → AVAudioConverter → float32 @ 16 kHz
  → WebSocket send (binary frames, raw float32 LE, see docs/PROTOCOL.md)

WebSocket receive (converted float32 @ 16 kHz, arrives in ~120 ms bursts)
  → ring/jitter buffer (target depth ~2 bursts ≈ 240 ms worst case, adaptive shrink)
  → AVAudioConverter → float32 @ output-device rate (usually 48 kHz)
  → AVAudioEngine/AudioUnit output rendering INTO the "XVC Mic" device
```

Implementation notes:
- **Capture: use `AVAudioSinkNode`, NOT `installTap`.** `installTap`'s `bufferSize` is
  advisory and macOS ignores it: measured on macOS 15 it delivered **4800-frame (100 ms)**
  buffers whether we asked for 256, 512, 1024 or 2048, while the device itself was running
  512-frame (10.7 ms) buffers. Audio that only materialises every 100 ms cannot be sent
  sooner, so the server received input in clumps, completed windows in clumps, and returned
  a ~100 ms latency tail that no client-side buffering can remove. `AVAudioSinkNode` hands
  you the device's own granularity. Switching cost us nothing and removed the tail entirely
  (`docs/BENCHMARKS.md`). Request mic permission (TCC) — add `NSMicrophoneUsageDescription`;
  a menu-bar app still gets the standard prompt.
- **Send cadence:** forward each captured buffer immediately after resampling (~11 ms
  chunks). The server accepts any chunk length; smaller chunks shave latency. Chunk *size*
  turned out not to matter; chunk *regularity* mattered enormously.
- **WebSocket:** `URLSessionWebSocketTask`. First message from server is JSON — wait
  for `{"status":"ready"}` before streaming (PROTOCOL.md). For the dev/KTH server the
  cert is self-signed: implement `urlSession(_:didReceive:completionHandler:)` trust
  override **gated behind a "trust this server" dev setting**, never unconditional.
- **Jitter buffer:** output arrives in bursts (server emits `CURRENT_MS` at a time).
  Prime playback after ~1.5 bursts of audio are buffered; on underrun emit silence and
  re-prime rather than glitching. Track buffer depth to display live latency.
- **The buffer must shrink itself.** Priming overshoots — you wait for 2880 frames but
  audio arrives in indivisible 1920-frame bursts, so playback starts holding ~3840. Input
  and output both run at 16 kHz, so nothing ever drains that excess: it becomes permanent
  latency whose size is decided by luck. Measured, p50 wandered 417–511 ms across runs with
  identical settings. Fix: watch the buffer's low-water mark over a ~0.5 s window, and drop
  depth that never gets used, splicing with a ~4 ms cross-fade so it doesn't click.
- **The trough must adapt, not be a constant.** A fixed 40 ms trough passed 18 s tests and
  then underran 7 times in 2 minutes: the shrink parks the buffer exactly at the trough,
  leaving no margin for arrival jitter (~28 ms on the KTH path). Grow the trough 20 ms on
  every underrun and let the buffer find its own floor — 100 ms, here. Start the guess at
  80 ms. See `docs/BENCHMARKS.md`.
- **Playout into the virtual mic:** the virtual device is an output like any other —
  create a second `AVAudioEngine` (or `AudioUnit`) whose output device is set to the
  "XVC Mic" device UID (`kAudioOutputUnitProperty_CurrentDevice` /
  `AVAudioEngine.outputNode` device selection via `AudioUnitSetProperty`). Whatever the
  app renders there appears at the device's input side, which meeting apps read.
- **No makeup gain on the converted audio.** X-VC normalizes loudness toward the target,
  so its output already sits near full scale — measured peak 0.985 from a source peaking
  at 0.275 (`docs/BENCHMARKS.md`). A quiet mic tempts you to add gain; adding it clips.
  If protection is wanted, use a soft limiter on the playout path.
- Optional monitor toggle: also render to the real speakers/headphones so the user can
  hear their converted voice ("hear myself" — off by default, it's distracting).

## 2. The virtual microphone ("XVC Mic")

A normal app cannot create a mic; macOS requires an **audio driver**. Solved pattern:

- Fork **BlackHole** (github.com/ExistentialAudio/BlackHole, **MIT license** — keep the
  license file and attribution). It is a user-space **AudioServerPlugIn** (HAL plug-in),
  NOT a kernel extension — no special Apple entitlement needed, just normal signing.
- Rebrand: device name "XVC Mic", new bundle ID, new device UID. Every constant is
  `#ifndef`-guarded in `BlackHole.c`, so **inject a prefix header with clang's `-include`**
  (`mac/driver/xvcmic_names.h`) rather than vendoring or patching their source — upstream
  then rebases for free. 2-channel, 44.1/48 kHz (meeting apps expect a normal-looking
  device; the app resamples 16 kHz up before rendering into it).
- **Do not use `GCC_PREPROCESSOR_DEFINITIONS` for the device name**, as BlackHole's README
  suggests. The name contains a space, and `-DkDevice_Name="XVC Mic"` is split on it before
  clang sees it. Escaping does not help — xcodebuild strips the backslash, so `"XVC\40Mic"`
  arrives as the literal `XVC40Mic`: **it builds successfully and silently ships a device
  named "XVC40Mic"**. Always `strings` the built binary and assert the name is right; a
  green build proves nothing here.
- **Give the plug-in its own factory UUID.** It is identified by the UUID in its
  `Info.plist`, and BlackHole ships a fixed one — a rebranded copy that keeps it collides
  with a real BlackHole install. Use a *stable* UUID (not freshly generated per build, or
  every rebuild leaves a phantom device behind in CoreAudio).
- Ad-hoc signing (`CODE_SIGN_IDENTITY=-`) is enough for local installs: a HAL plug-in is
  user-space, so no Apple entitlement is involved. The stock project wants a "Mac
  Development" cert and fails without this.
- Install location: `/Library/Audio/Plug-Ins/HAL/XVCMic.driver` — requires **one-time
  admin authentication**, then restart CoreAudio (`sudo killall coreaudiod`; it
  respawns instantly). Every audio product (Krisp, Loopback, VB-Cable) has this step;
  it is unavoidable and fine.
- Ship it inside a **`.pkg` installer** that installs both the `.app` and the driver in
  one flow (productbuild with two component packages + postinstall script that bounces
  coreaudiod). The user experience: download one file → install (password once) →
  "XVC Mic" appears in every app's mic picker.
- Signing/notarization (when distributing beyond the team): Developer ID certificate,
  `codesign` app + driver, `notarytool` the pkg. Until then, right-click-open works
  for internal testing.

How the loopback works (why writing to an output becomes a mic): BlackHole-style
drivers expose one device with both output and input streams sharing a ring buffer —
audio rendered to its output is readable at its input. No extra glue needed.

## 3. Menu-bar UI (Phase 4 — keep Phase 1–2 headless/CLI)

- **Target voice picker**: list of saved WAVs; "Add voice…" uploads via
  `POST /api/meanvc/load-target` (multipart field `wav`), stores returned `target_id`.
  Re-upload transparently when the server restarts (`Unknown target_id` error frame).
- **Server settings**: URL (`wss://host:5002`), auth token, "trust self-signed cert"
  dev toggle.
- **Main toggle**: Convert ON/OFF. OFF should pass the real mic through to XVC Mic
  (so the user doesn't have to switch devices in Zoom mid-call) — implement
  passthrough as the same pipeline minus the network hop.
- **Live readouts**: input level meter, end-to-end latency estimate (from jitter-buffer
  depth + RTT ping), connection state.
- Menu-bar icon states: idle / connecting / converting / error.

### 3.1 Immediate toggle in the status bar

The toggle sits in the system status bar (the strip where the Wi-Fi and battery icons
live) as an `NSStatusItem`, and must flip conversion on/off **in one click, mid-call,
without opening a menu** — the user is speaking when they reach for it.

- **Click behavior**: `statusItem.button` with
  `sendAction(on: [.leftMouseUp, .rightMouseUp])`. Left click toggles Convert directly;
  right click (and click-and-hold) opens the menu with the target picker, server
  settings, and quit. Never put the toggle behind the menu — that is two clicks and a
  read.
- **Global hotkey** for toggling without leaving the meeting window. The status bar is
  covered by full-screen apps on some setups, so the hotkey is the real path, not a
  nicety. (Zoom is often full-screen; that is exactly when you need this.)
- **Icon states** as SF Symbol *template* images so they track the light/dark menu bar:
  idle (`mic.slash`), connecting (`mic.badge.ellipsis`, animated), converting (filled +
  accent tint), error (`exclamationmark.triangle`). The converting state must be
  distinguishable at a glance and in peripheral vision — this icon is the only feedback
  that the far end is hearing the converted voice rather than the real one.
- **Toggling must not tear down the audio engines.** Both are already running (§1); the
  toggle only chooses which source feeds the playout node into XVC Mic. Rebuilding an
  engine mid-call drops audio for hundreds of milliseconds and Zoom may see the device
  disappear.
- **Cross-fade the switch** (~20 ms raised cosine, same shape as the server's window
  smoothing) — a hard cut between the real and converted voice is an audible click.
- **Turning Convert ON has a pipeline-fill delay** of roughly one end-to-end latency
  (~350–450 ms, PERFORMANCE.md §2) before the first converted samples arrive. Keep
  passthrough audio flowing during the fill and cross-fade when the first converted
  buffer lands, so the toggle never produces a gap. Show the connecting icon during it.
  Turning OFF is immediate (passthrough is always live).
- Consequence for §1: the playout node's source has to be switchable at buffer
  granularity. Design it that way when Phase 2 wires playout into the virtual mic —
  the UI arrives later, but a playout node that can only be re-pointed by restarting
  the engine cannot support this toggle.

## 4. Failure behaviors (decide up front, they define perceived quality)

| Event | Behavior |
|---|---|
| WebSocket drops mid-call | auto-reconnect with backoff; play silence into XVC Mic meanwhile (meeting app sees a quiet mic, not a dead device); re-upload target if needed |
| Server can't keep up (rising buffer/latency) | surface it in the UI ("server overloaded"); optional auto-fallback to passthrough |
| Laptop sleeps / device changes | rebuild both engines on `AVAudioEngineConfigurationChange` |
| No mic permission | clear one-click guidance to System Settings |

## 5. Project layout suggestion

```
mac/
  XVCLiveMic/            # SwiftUI menu-bar app (SPM or Xcode project)
    AudioPipeline/       # capture, resample, jitter buffer, playout
    Network/             # WS client, protocol handshake, load-target upload
    UI/
  XVCMicDriver/          # BlackHole fork (C), renamed constants, own LICENSE
  installer/             # pkgbuild/productbuild scripts, postinstall (coreaudiod bounce)
server/                  # trimmed X-VC server + setup.sh + bench.py (docs/BACKEND.md)
```
