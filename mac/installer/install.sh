#!/bin/bash
# One-line installer for XVC Live Mic. Meant to be run via:
#
#   curl -fsSL https://raw.githubusercontent.com/syedfahimabrar/xvc-front/main/mac/installer/install.sh | bash
#
# Why a script instead of just double-clicking the .pkg: on macOS 15 (Sequoia) an unsigned,
# downloaded .pkg is blocked by Gatekeeper with no reliable GUI override. A script run
# explicitly through `bash` (as above) is NOT subject to that quarantine gate, so it can
# download the pkg, clear the "downloaded" flag, and install it cleanly. This is the same
# mechanism Homebrew's installer uses.
set -euo pipefail

REPO="syedfahimabrar/xvc-front"
ASSET="XVCLiveMic.pkg"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

[ "$(uname)" = "Darwin" ] || { echo "This installer is for macOS only." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading XVC Live Mic…"
if ! curl -fSL "$URL" -o "$TMP/$ASSET"; then
    echo "Could not download $URL" >&2
    echo "Make sure a release has been published (git tag v… && push)." >&2
    exit 1
fi

# The download carries the Gatekeeper quarantine flag; clear it so the pkg installs without
# the 'unidentified developer' block. (This is exactly what signing would make unnecessary.)
xattr -dr com.apple.quarantine "$TMP/$ASSET" 2>/dev/null || true

say "Installing (you'll be asked for your password — it's needed to add the audio device)…"
sudo installer -pkg "$TMP/$ASSET" -target /

# The pkg only lays the app down; launch it so the menu-bar icon actually appears. (This
# runs as you, not root — `sudo` above was scoped to the installer command alone.)
say "Starting XVC Live Mic…"
open -a "/Applications/XVC Live Mic.app" || true

cat <<'EOF'

  XVC Live Mic is installed and running — look for the microphone icon in your menu bar.

  Next:
    1. Click the icon → Server settings, and enter the server address, port and token.
    2. Click the icon → Add voice…, and choose a target-voice .wav file.
    3. Left-click the icon to turn Convert ON (allow microphone access when asked).
    4. In Zoom / Google Meet / Teams, pick "XVC Mic" as your microphone.

EOF
