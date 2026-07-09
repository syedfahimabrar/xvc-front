#!/usr/bin/env bash
# Build the "XVC Mic" virtual audio device: a rebranded BlackHole (MIT).
#
# BlackHole exposes every name we need as a pre-compiler constant, so this is a rebrand
# via build flags rather than a source fork — upstream fixes rebase for free. See
# docs/MAC_APP.md §2.
#
#   ./build.sh          # build driver/build/XVCMic.driver
#   ./build.sh install  # ...then install it (asks for your password)
set -euo pipefail

BLACKHOLE_TAG=v0.7.1
DRIVER_NAME=XVCMic                      # also becomes the device UID: XVCMic_UID
DEVICE_NAME="XVC Mic"                   # what Zoom/Meet show in the mic picker
BUNDLE_ID=se.kth.xvclivemic.driver

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/BlackHole"
OUT="$HERE/build"
DRIVER="$OUT/$DRIVER_NAME.driver"
HAL=/Library/Audio/Plug-Ins/HAL

if [ ! -d "$SRC" ]; then
    echo "[driver] cloning BlackHole $BLACKHOLE_TAG ..."
    git clone --depth 1 --branch "$BLACKHOLE_TAG" \
        https://github.com/ExistentialAudio/BlackHole.git "$SRC"
fi

if [ "${1:-}" != "install" ]; then
    rm -rf "$OUT"
    echo "[driver] building $DEVICE_NAME (2ch, 44.1/48 kHz) ..."
    # kNumber_Of_Channels=2 and 44.1/48 kHz: meeting apps expect a normal-looking device.
    # The app resamples 16 kHz -> device rate before rendering into it.
    # kPlugIn_Icon stays BlackHole.icns because that file is what ships in the bundle's
    # Resources; swap both together when we have our own artwork.
    xcodebuild \
        -project "$SRC/BlackHole.xcodeproj" \
        -configuration Release \
        -target BlackHole \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        CONFIGURATION_BUILD_DIR="$OUT" \
        GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
            kDriver_Name="'"$DRIVER_NAME"'"
            kPlugIn_BundleID="'"$BUNDLE_ID"'"
            kPlugIn_Icon="BlackHole.icns"
            kDevice_Name="'"$DEVICE_NAME"'"
            kDevice2_Name="'"$DEVICE_NAME" Mirror"'"
            kNumber_Of_Channels=2
            kSampleRates=44100,48000' \
        2>&1 | tail -3

    # xcodebuild names the product after the target, not after kDriver_Name.
    [ -d "$OUT/BlackHole.driver" ] && mv "$OUT/BlackHole.driver" "$DRIVER"
    echo "[driver] built $DRIVER"
    echo
    echo "Install it with:  $0 install"
    exit 0
fi

[ -d "$DRIVER" ] || { echo "error: build it first ($0)" >&2; exit 1; }

# A HAL plug-in lives in a root-owned directory and CoreAudio only rescans on restart.
# Every audio product does exactly this (Krisp, Loopback, VB-Cable); it is unavoidable.
echo "[driver] installing to $HAL (needs admin) ..."
sudo rm -rf "$HAL/$DRIVER_NAME.driver"
sudo cp -R "$DRIVER" "$HAL/"
sudo chown -R root:wheel "$HAL/$DRIVER_NAME.driver"
echo "[driver] restarting coreaudiod (audio will glitch for a second) ..."
sudo killall coreaudiod
sleep 2

echo
echo "[driver] installed. It should now appear as \"$DEVICE_NAME\":"
system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME" \
    && echo "  found in the audio device list" \
    || echo "  NOT found yet — give coreaudiod a moment, or check Console.app for load errors"
