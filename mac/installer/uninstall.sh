#!/usr/bin/env bash
# Completely remove XVC Live Mic: the app, the XVC Mic audio device, and per-user data.
# Run it directly (it will ask for your password to remove the system audio device):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/syedfahimabrar/xvc-front/main/mac/installer/uninstall.sh)
#
# or, from a clone:  ./uninstall.sh
set -euo pipefail

echo "Removing XVC Live Mic…"

# App (from a normal install).
sudo rm -rf "/Applications/XVC Live Mic.app"

# The XVC Mic audio device, then restart CoreAudio so it disappears (audio blips briefly).
sudo rm -rf /Library/Audio/Plug-Ins/HAL/XVCMic.driver
sudo killall coreaudiod 2>/dev/null || true

# Per-user data (no sudo): saved server/token/targets, and the mic-permission grant.
defaults delete se.kth.xvclivemic 2>/dev/null || true
tccutil reset Microphone se.kth.xvclivemic 2>/dev/null || true

echo "Done. XVC Mic and the app are gone."
