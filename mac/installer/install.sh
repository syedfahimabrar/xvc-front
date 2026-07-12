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

say "Done. Look for the microphone icon in your menu bar."
say "Open it → Server settings to configure, then pick \"XVC Mic\" as your mic in Zoom/Meet."
