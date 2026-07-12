# Installing XVC Live Mic

The installer is **not signed with an Apple Developer certificate** (that needs a paid
Apple Developer account). It works fine — macOS just adds a couple of one-time confirmation
steps, described below. Everything is verified: the bundled "XVC Mic" driver is ad-hoc
signed and loads normally on current macOS.

## Install

Because the installer isn't signed (that needs a paid Apple Developer account), a
*downloaded* `.pkg` is blocked by macOS Gatekeeper and — on macOS 15 (Sequoia) — has no
reliable click-through override. The easiest reliable install is one line in Terminal.

### Easy way — one command

Open **Terminal** (Spotlight → type "Terminal") and paste this, then press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/syedfahimabrar/xvc-front/main/mac/installer/install.sh | bash
```

It downloads the installer, gets it past Gatekeeper, and installs the app + the "XVC Mic"
audio device. Enter your Mac password when asked (it's needed to add the audio device).
That's it — the mic icon appears in your menu bar.

*(A script run this way is not subject to the block that stops the double-click — the same
mechanism Homebrew's installer uses. A signed build would remove even this one line.)*

### Manual way — if you'd rather not use the one-liner

1. **Download** `XVCLiveMic.pkg` (note where it saved, e.g. `~/Downloads`).
2. In **Terminal**, clear the download flag so Gatekeeper lets it install:
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/XVCLiveMic*.pkg
   ```
3. **Double-click the pkg** — it now opens normally. Click through and enter your admin
   password when asked.
4. Done. **XVC Live Mic** is in `/Applications`, mic icon in the menu bar.

## First use

1. Click the **mic icon** in the menu bar → **Server settings**. Enter the server host,
   port, and your auth token (ask whoever runs the server), tick **Trust self-signed
   certificate**, and pick your real microphone. Save.
2. Click the icon → **Add voice…** and choose a target-voice `.wav`.
3. **Left-click the icon to turn Convert ON.** macOS asks for **microphone access** the
   first time — click **Allow**.
   - The icon turns **green** while converting (your converted voice), and is a plain
     outline mic in passthrough (your real voice). Left-click toggles between them.
4. In your meeting app (Zoom, Google Meet, Teams…), choose **XVC Mic** as the
   **microphone**. Leave your speaker/headphones as they are.
   - Keep your normal speakers as the *output* — never pick XVC Mic as your speaker, or you
     won't hear the other people.

> **FaceTime and WhatsApp do not work** with XVC Mic — they use Apple's voice-processing
> audio unit, which mutes virtual microphones. Use Zoom / Meet / Teams.

## If "XVC Mic" doesn't appear in your meeting app

Two things to try, in order:

1. **Fully quit and reopen the meeting app** (⌘Q). Apps read the microphone list once at
   launch, so XVC Mic won't show up in an app that was already open when you installed.
2. **Clear the download flag on the driver and restart CoreAudio** (only if step 1 didn't
   help — this is rarely needed, since the installer places files without the flag):
   ```bash
   sudo xattr -dr com.apple.quarantine "/Library/Audio/Plug-Ins/HAL/XVCMic.driver"
   sudo killall coreaudiod
   ```

## Uninstall

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/XVCMic.driver"
sudo killall coreaudiod
rm -rf "/Applications/XVC Live Mic.app"
```

---

*Getting a signed, notarized installer (double-click to install, no warnings) needs an
Apple Developer Program membership — see `.github/workflows/installer.yml` for the secrets
to add once a certificate is available.*
