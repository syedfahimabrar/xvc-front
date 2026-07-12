# Installing XVC Live Mic

The installer is **not signed with an Apple Developer certificate** (that needs a paid
Apple Developer account). It works fine — macOS just adds a couple of one-time confirmation
steps, described below. Everything is verified: the bundled "XVC Mic" driver is ad-hoc
signed and loads normally on current macOS.

## Install

1. **Download** `XVCLiveMic-<version>.pkg`.
2. **Right-click it → Open** (a plain double-click is blocked with *"unidentified
   developer"* — right-click → Open gets past it). Click **Open** again to confirm.
   - On newer macOS you may instead see the block, then go to **System Settings → Privacy
     & Security**, scroll down, and click **Open Anyway**.
3. The installer runs. **Enter your admin password** when asked — it needs it to place the
   "XVC Mic" audio driver in `/Library/Audio/Plug-Ins/HAL/` and restart CoreAudio (all
   audio blips for a second; this is normal, every audio app does it).
4. Done. **XVC Live Mic** is in `/Applications` and its mic icon is in the menu bar.

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
