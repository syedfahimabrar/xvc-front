# XVC Live Mic

Speak in a converted voice in **any** meeting app — Zoom, Google Meet, Teams — in real
time, on macOS.

The voice conversion (X-VC, zero-shot streaming voice conversion) runs on a remote GPU
server. A native macOS menu-bar app captures your microphone, streams it to the server,
and plays the converted audio into a bundled virtual microphone called **XVC Mic**, which
meeting apps select like any normal microphone. End-to-end latency is roughly a third of a
second.

```
your mic ─► [Mac app] ─16 kHz PCM/WSS─► [GPU server: X-VC] ─converted PCM─► [Mac app]
                                                                               │
                                              meeting app ◄─ "XVC Mic" ◄───────┘
                                              (picks XVC Mic as its microphone)
```

The heavy lifting (a Whisper-class semantic tokenizer plus the acoustic model) needs a CUDA
GPU, so it lives on the server. The Mac side only moves audio — it runs on any Mac from the
last decade.

---

## Contents

- [How it works](#how-it-works)
- [Part 1 — Install the backend (GPU server)](#part-1--install-the-backend-gpu-server)
  - [Server parameters](#server-parameters)
  - [Tuning latency vs. GPU load](#tuning-latency-vs-gpu-load)
- [Part 2 — Install the app (macOS)](#part-2--install-the-app-macos)
- [Building from source](#building-from-source)
- [Repository layout](#repository-layout)
- [Credits](#credits)

---

## How it works

- The **app** captures the mic with `AVAudioEngine`, resamples to 16 kHz mono float32, and
  streams it over a WebSocket to the server. Converted audio comes back in ~120–240 ms
  bursts; a small adaptive jitter buffer smooths them and renders into the XVC Mic device.
- The **server** runs X-VC's official streaming inference. For each output window it runs a
  full forward pass over a 2.4 s context; only a slice of that is emitted, cross-faded with
  the previous window. Target voices are registered once (`load-target`) and streamed
  against (`stream`).
- **XVC Mic** is a virtual audio device (a rebranded [BlackHole](https://github.com/ExistentialAudio/BlackHole),
  a user-space Core Audio plug-in). Whatever the app renders to its output appears at its
  input, which meeting apps read as a microphone.

> **Compatibility note.** XVC Mic works with apps that do their own audio processing —
> Zoom, Google Meet, Microsoft Teams, Discord, OBS. It does **not** work with FaceTime or
> WhatsApp, which route the mic through Apple's voice-processing unit and mute virtual
> microphones.

---

## Part 1 — Install the backend (GPU server)

**Requirements:** a Linux box (Ubuntu 22.04) with an NVIDIA GPU and driver installed
(`nvidia-smi` works). The model uses ~3 GB of VRAM, so any 6 GB+ GPU is comfortable; an
RTX 3080 / 3090 / 4090 or an L40S / A100 all work well. A CUDA GPU is required — the model
cannot run on the Mac or on CPU in real time.

### One-command setup

```bash
git clone https://github.com/smfabrar/xvc-front.git
cd xvc-front/server
XVC_DIR=~/X-VC ./setup.sh
```

`setup.sh` is idempotent and does everything:

1. Installs `uv` and `ffmpeg` if missing.
2. Clones the X-VC inference code at a pinned commit into `$XVC_DIR`.
3. Creates the Python 3.10 environment (`uv sync`, torch cu121).
4. Downloads the three model assets (checkpoint, GLM-4-Voice tokenizer, ERes2Net speaker
   encoder), skipping any already present.
5. Generates a 10-year self-signed TLS certificate in `~/xvc-ssl` (prints its SHA-256
   fingerprint) and an auth token in `~/xvc-token`.
6. Writes a `systemd` unit if you have root, otherwise a plain launch script.
7. Runs a one-off GPU benchmark so you can confirm the box keeps up (expect p95 per window
   well under 100 ms on any modern GPU).

> If the box has a real DNS hostname, set `XVC_PUBLIC_HOST=your.host.name` before running
> and `setup.sh` will obtain a Let's Encrypt certificate instead of self-signing.

### Run it

```bash
cd server
./run.sh                       # foreground, uses the defaults
# or, detached, and wait until it is ready to serve:
./restart.sh
# or, if setup.sh installed the systemd unit (root):
sudo systemctl enable --now xvc-server
```

Wait for `[xvc] warmed up` in the log — the server runs one dummy conversion at startup so
the first real connection doesn't pay a cold-start penalty. Then note two things to give to
each user:

- **Server address** — the box's IP or hostname (port 5002 by default).
- **Auth token** — the contents of `~/xvc-token`.

### Server parameters

Everything is an environment variable with a sensible default. `run.sh` sets these; override
any of them inline (`XVC_CURRENT_MS=120 ./run.sh`) or in the systemd unit.

| Variable | Default | Meaning |
|---|---|---|
| `XVC_AUTH_TOKEN` | *(empty)* | Bearer token clients must present. **Empty means the server is open** — always set this for anything reachable. `setup.sh` generates one into `~/xvc-token`. |
| `MEANVC_PORT` | `5002` | Port to listen on (HTTPS/WSS). |
| `SSL_DIR` | `~/xvc-ssl` | Directory holding `cert.pem` / `key.pem`. If absent, the server runs plain HTTP (dev only). |
| `XVC_DIR` | `~/X-VC` | Path to the cloned X-VC repo. Must also be the working directory (the model uses relative paths). `run.sh` handles this. |
| `XVC_CONFIG` | `$XVC_DIR/configs/xvc.yaml` | Model config. |
| `XVC_CKPT` | `$XVC_DIR/ckpts/xvc.pt` | Model checkpoint. |
| `XVC_DEVICE` | `0` | CUDA device index. |
| `XVC_EMA_LOAD` | `1` | Load EMA (exponential-moving-average) weights. |
| `XVC_CHUNK_MS` | `2400` | The full context window the model runs over per forward pass (history + current + smooth + future). Larger = more context, more compute. Shrinking it makes each forward cheaper but risks quality — the model was trained at 2.4 s. |
| `XVC_CURRENT_MS` | `240` | **The main latency/throughput lever** — how much converted audio each window emits. See [tuning](#tuning-latency-vs-gpu-load) below. |
| `XVC_SMOOTH_MS` | `20` | Cross-fade overlap between consecutive windows (prevents clicks at the seams). |
| `XVC_FUTURE_MS` | `100` | Look-ahead the model sees past the current region. Part of the fixed algorithmic latency. |

Constraint enforced by the server: `CHUNK − CURRENT − SMOOTH − FUTURE ≥ 0`.

**Auth mechanics.** A single shared bearer token. `load-target` requires it as an HTTP
header (`Authorization: Bearer <token>`); the streaming WebSocket requires it as a query
parameter (`?token=<token>`, because WebSocket clients can't set headers reliably). Wrong
or missing → HTTP 401, compared in constant time. Generate or rotate a token with
`openssl rand -hex 32`; put it in `~/xvc-token` and restart. Everyone shares the same token
— to give different people revocable tokens you'd extend the check to a set of tokens.

### Tuning latency vs. GPU load

`XVC_CURRENT_MS` trades latency against GPU load. Each window costs roughly the same to
compute (dominated by the fixed 2.4 s context), so emitting *more* per window means *fewer*
windows per second and less GPU work — at the cost of latency. Change it and restart:

```bash
XVC_CURRENT_MS=240 ./restart.sh    # default: smooth, ~0.14x GPU load
XVC_CURRENT_MS=120 ./restart.sh    # balanced
XVC_CURRENT_MS=60  ./restart.sh    # lowest latency, ~2x the GPU work of 120
```

| `CURRENT_MS` | Mic-to-ear latency | GPU load (RTX 3080) | Character |
|---|---|---|---|
| 240 *(default)* | ~490 ms | ~0.14× | smoothest seams, most headroom for many users |
| 120 | ~370 ms | ~0.27× | balanced |
| 60 | ~290 ms | ~0.54× | snappiest, but converts twice as often |

`restart.sh` prints the resulting look-ahead floor so you can see the effect before
connecting, then waits until the model has warmed up. Pick by ear as well as by number —
the settings change how the cross-fades sound, not just the delay.

---

## Part 2 — Install the app (macOS)

### Install

Open **Terminal** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/smfabrar/xvc-front/main/mac/installer/install.sh | bash
```

This downloads the installer, installs **XVC Live Mic** into `/Applications`, installs the
**XVC Mic** audio device (you'll be asked for your Mac password — it's needed to add a
system audio device), and starts the app. A microphone icon appears in your menu bar.

The app is a menu-bar app with no Dock icon — the menu-bar microphone icon *is* the app. If
you ever quit it, reopen it from `/Applications`.

<details>
<summary>Prefer to install manually?</summary>

Download `XVCLiveMic.pkg` from the [latest release](https://github.com/smfabrar/xvc-front/releases/latest),
then in Terminal:

```bash
xattr -dr com.apple.quarantine ~/Downloads/XVCLiveMic*.pkg   # clear the download flag
open ~/Downloads/XVCLiveMic*.pkg                             # double-click installer
```
</details>

### First use

1. Click the **microphone icon** in the menu bar → **Server settings**. Enter the server
   **address**, **port** (5002), and **auth token** (from whoever runs the server). Tick
   **Trust self-signed certificate**, choose your real microphone, and Save.
2. Click the icon → **Add voice…** and choose a target-voice `.wav` file (a few seconds of
   clean speech of the voice you want to sound like).
3. **Left-click the icon to turn Convert ON.** The first time, macOS asks for microphone
   access — click Allow. The icon turns **green** while converting.
4. In your meeting app (Zoom, Google Meet, Teams…), select **XVC Mic** as the
   **microphone**. Leave your speakers/headphones as they are.

The menu-bar icon tells you the state at a glance:

| Icon | State |
|---|---|
| plain outline mic | **passthrough** — the far end hears your real voice |
| green filled mic | **converting** — the far end hears the converted voice |
| orange mic | connecting |
| red triangle | error (right-click for details) |

**Left-click toggles Convert on/off** in a single click, even mid-call. When it's off, your
real voice passes straight through to XVC Mic, so you never have to change the microphone in
your meeting app. **Right-click** opens the full menu (target picker, settings, quit).

> Keep your normal speakers/headphones as your *output*. Never select XVC Mic as your
> speaker, or you won't hear the other people.

### Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/smfabrar/xvc-front/main/mac/installer/uninstall.sh)
```

Removes the app, the XVC Mic device, and its saved settings.

---

## Building from source

### Backend

```bash
cd server
XVC_DIR=~/X-VC ./bootstrap.sh    # environment + models only (setup.sh is the superset)
# then: cd ~/X-VC && uv run --project <repo>/server python <repo>/server/xvc_server.py
```

`bench.py` benchmarks a GPU; `probe_stream.py` (under `tools/`) is a synthetic client that
measures end-to-end latency against a running server.

### macOS app, driver, and installer

Requires Xcode command-line tools.

```bash
cd mac
swift build                        # builds the app + the xvc-cli test harness
./build-app.sh run                 # assemble "XVC Live Mic.app" and launch it
./driver/build.sh install          # build + install the XVC Mic virtual device
./installer/build-pkg.sh           # build the one-download .pkg (app + driver)
```

Pushing a `v*` git tag builds the installer in CI and publishes it as a GitHub Release
(`.github/workflows/installer.yml`).

---

## Repository layout

```
server/                 GPU backend
  xvc_server.py         the streaming server (load-target + stream + token auth + warm-up)
  setup.sh              one-command provisioning (env + models + TLS + token + systemd)
  run.sh / restart.sh   launch with tunable parameters
  bootstrap.sh          environment + model download only
  bench.py              GPU benchmark
  pyproject.toml        pinned Python environment
tools/
  probe_stream.py       synthetic latency-measurement client
mac/
  Sources/XVCCore/      shared audio pipeline (capture, jitter buffer, WS client, devices)
  Sources/XVCLiveMic/   the menu-bar app
  Sources/xvc-cli/      headless CLI (test harness for the pipeline)
  driver/               the "XVC Mic" virtual device (rebranded BlackHole) + build script
  installer/            .pkg builder, one-line install.sh, app icon
  build-app.sh          assemble the .app bundle
.github/workflows/      CI that builds and releases the installer
docs/reference/         the original server this backend was derived from (read-only)
```

---

## Credits

- **XVC Mic** is a rebrand of [BlackHole](https://github.com/ExistentialAudio/BlackHole)
  by Existential Audio, used under the MIT license. Its LICENSE ships inside the driver.
- Voice conversion uses [X-VC](https://github.com/Jerrister/X-VC) (zero-shot streaming voice
  conversion) and its released model weights.
