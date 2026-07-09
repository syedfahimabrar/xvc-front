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
- **Capture:** `AVAudioEngine.inputNode.installTap` with a small buffer (e.g. 1024
  frames @ 48 kHz ≈ 21 ms). Request mic permission (TCC) — add
  `NSMicrophoneUsageDescription`; a menu-bar app still gets the standard prompt.
- **Send cadence:** forward each tap buffer immediately after resampling (~20 ms
  chunks). The server accepts any chunk length; smaller chunks shave latency.
- **WebSocket:** `URLSessionWebSocketTask`. First message from server is JSON — wait
  for `{"status":"ready"}` before streaming (PROTOCOL.md). For the dev/KTH server the
  cert is self-signed: implement `urlSession(_:didReceive:completionHandler:)` trust
  override **gated behind a "trust this server" dev setting**, never unconditional.
- **Jitter buffer:** output arrives in bursts (server emits `CURRENT_MS` at a time).
  Prime playback after ~1.5 bursts of audio are buffered; on underrun emit silence and
  re-prime rather than glitching. Track buffer depth to display live latency.
- **Playout into the virtual mic:** the virtual device is an output like any other —
  create a second `AVAudioEngine` (or `AudioUnit`) whose output device is set to the
  "XVC Mic" device UID (`kAudioOutputUnitProperty_CurrentDevice` /
  `AVAudioEngine.outputNode` device selection via `AudioUnitSetProperty`). Whatever the
  app renders there appears at the device's input side, which meeting apps read.
- Optional monitor toggle: also render to the real speakers/headphones so the user can
  hear their converted voice ("hear myself" — off by default, it's distracting).

## 2. The virtual microphone ("XVC Mic")

A normal app cannot create a mic; macOS requires an **audio driver**. Solved pattern:

- Fork **BlackHole** (github.com/ExistentialAudio/BlackHole, **MIT license** — keep the
  license file and attribution). It is a user-space **AudioServerPlugIn** (HAL plug-in),
  NOT a kernel extension — no special Apple entitlement needed, just normal signing.
- Rebrand: device name "XVC Mic", new bundle ID, new device UID (constants at the top
  of `BlackHole.h` — name, UID, bundle ID, icon). 2-channel, 48 kHz is fine (also build
  16 kHz? No — meeting apps expect 44.1/48 kHz; resample in the app).
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
