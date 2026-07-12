# Installing XVC Live Mic

The installer is **not signed with an Apple Developer certificate** (that needs a paid
Apple Developer account). It works fine — macOS just adds a couple of one-time confirmation
steps, described below. Everything is verified: the bundled "XVC Mic" driver is ad-hoc
signed and loads normally on current macOS.

## Install

Because the installer isn't signed, macOS Gatekeeper blocks a downloaded `.pkg`. On
**macOS 15 (Sequoia)** the block shows only **Done / Move to Trash**, and the usual
"Open Anyway" button in Privacy & Security often does **not** appear for installer
packages. The reliable route is to clear the "downloaded" flag first:

1. **Download** `XVCLiveMic-<version>.pkg` (note where it saved, e.g. `~/Downloads`).
2. Open **Terminal** (Applications → Utilities) and run — adjust the path to where the pkg
   is — to remove the download flag:
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/XVCLiveMic-*.pkg
   ```
3. Now **double-click the pkg** — it opens normally, no Gatekeeper warning.
4. Click through the installer and **enter your admin password** when asked — it needs it
   to place the "XVC Mic" audio driver in `/Library/Audio/Plug-Ins/HAL/` and restart
   CoreAudio (all audio blips for a second; normal, every audio app does it).
5. Done. **XVC Live Mic** is in `/Applications` and its mic icon is in the menu bar.

> One command in step 2 is the price of an unsigned installer on current macOS. A signed,
> notarized build (needs a paid Apple Developer account) removes it — plain double-click,
> no Terminal. Until then, the command above is safe and standard.

Prefer no Terminal at all? An admin can also install headless:
`sudo installer -pkg XVCLiveMic-*.pkg -target /` (the command-line installer skips the
Gatekeeper GUI entirely).

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
