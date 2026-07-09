#!/usr/bin/env bash
# Build the "XVC Mic" virtual audio device: a rebranded BlackHole (MIT license).
#
# We never vendor or patch BlackHole's sources — the build clones them at a pinned tag and
# injects our names with clang's `-include` (see xvcmic_names.h for why not -D). Upstream
# fixes rebase for free. See docs/MAC_APP.md §2.
#
#   ./build.sh            build build/XVCMic.driver
#   ./build.sh install    install to /Library/Audio/Plug-Ins/HAL (asks for your password)
#   ./build.sh uninstall  remove it again
set -euo pipefail

BLACKHOLE_TAG=v0.7.1
DRIVER_NAME=XVCMic
DEVICE_NAME="XVC Mic"
BUNDLE_ID=se.kth.xvclivemic.driver

# A HAL plug-in is identified by the factory UUID in its Info.plist. BlackHole ships one
# fixed UUID, so a rebranded copy MUST use a different one, or the two collide when both are
# installed. It must also be STABLE across our builds — a fresh UUID each time would leave a
# trail of phantom devices in CoreAudio.
FACTORY_UUID=25C1409F-4761-400D-B3A4-B4529CAC88C5
BLACKHOLE_UUID=e395c745-4eea-4d94-bb92-46224221047c

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/BlackHole"
OUT="$HERE/build"
DRIVER="$OUT/$DRIVER_NAME.driver"
HAL=/Library/Audio/Plug-Ins/HAL
INSTALLED="$HAL/$DRIVER_NAME.driver"

case "${1:-build}" in
uninstall)
    echo "[driver] removing $INSTALLED (needs admin) ..."
    sudo rm -rf "$INSTALLED"
    sudo killall coreaudiod
    echo "[driver] removed; coreaudiod restarted"
    exit 0
    ;;
install)
    [ -d "$DRIVER" ] || { echo "error: build it first: $0" >&2; exit 1; }
    # HAL plug-ins live in a root-owned directory and CoreAudio only rescans on restart.
    # Every audio product does exactly this (Krisp, Loopback, VB-Cable). Unavoidable.
    echo "[driver] installing to $HAL (needs admin) ..."
    sudo rm -rf "$INSTALLED"
    sudo cp -R "$DRIVER" "$INSTALLED"
    sudo chown -R root:wheel "$INSTALLED"
    echo "[driver] restarting coreaudiod (all audio glitches for a moment) ..."
    sudo killall coreaudiod
    sleep 3
    if system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME"; then
        echo "[driver] installed — \"$DEVICE_NAME\" is in the device list"
    else
        echo "[driver] NOT showing up. Check Console.app for coreaudiod load errors." >&2
        exit 1
    fi
    exit 0
    ;;
esac

if [ ! -d "$SRC" ]; then
    echo "[driver] cloning BlackHole $BLACKHOLE_TAG ..."
    git clone --quiet --depth 1 --branch "$BLACKHOLE_TAG" \
        https://github.com/ExistentialAudio/BlackHole.git "$SRC"
fi

rm -rf "$OUT"
echo "[driver] building \"$DEVICE_NAME\" (2ch, 44.1/48 kHz) ..."

# Ad-hoc signature: a HAL plug-in is user-space, not a kext, so no Apple entitlement is
# needed for local use. Distribution needs a Developer ID cert + notarization (MAC_APP.md §2).
xcodebuild \
    -project "$SRC/BlackHole.xcodeproj" \
    -configuration Release \
    -target BlackHole \
    CONFIGURATION_BUILD_DIR="$OUT" \
    OTHER_CFLAGS="-include $HERE/xvcmic_names.h" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# xcodebuild names the product after the Xcode target, not after kDriver_Name.
[ -d "$OUT/BlackHole.driver" ] && mv "$OUT/BlackHole.driver" "$DRIVER"

PLIST="$DRIVER/Contents/Info.plist"
sed -i '' "s/$BLACKHOLE_UUID/$FACTORY_UUID/g" "$PLIST"

# Verify, don't assume. An earlier attempt built successfully and silently produced a device
# named "XVC40Mic", because xcodebuild ate a backslash in a -D flag.
echo
echo "[driver] verifying the rebrand took:"
BIN="$DRIVER/Contents/MacOS/BlackHole"
[ -f "$BIN" ] || BIN="$(find "$DRIVER/Contents/MacOS" -type f -perm +111 | head -1)"
fail=0
expect() {  # expect <label> <needle> <haystack>
    if printf '%s' "$3" | grep -qF -- "$2"; then
        echo "  ok    $1: $2"
    else
        echo "  FAIL  $1: expected '$2'"; fail=1
    fi
}
SYMS="$(strings "$BIN")"
expect "device name" "$DEVICE_NAME"          "$SYMS"
expect "mirror name" "$DEVICE_NAME Mirror"   "$SYMS"
expect "device uid"  "${DRIVER_NAME}%ich_UID" "$SYMS"
expect "bundle id"   "$BUNDLE_ID"            "$(defaults read "$PLIST" CFBundleIdentifier)"
expect "our uuid"    "$FACTORY_UUID"         "$(cat "$PLIST")"
if grep -qF "$BLACKHOLE_UUID" "$PLIST"; then
    echo "  FAIL  uuid: BlackHole's factory UUID is still present"; fail=1
else
    echo "  ok    uuid: BlackHole's factory UUID is gone"
fi
if printf '%s' "$SYMS" | grep -qE '^BlackHole( |$)'; then
    echo "  warn  binary still contains a bare 'BlackHole' string (icon/target name, harmless)"
fi
[ $fail -eq 0 ] || { echo; echo "error: rebrand incomplete — do NOT install this" >&2; exit 1; }

echo
echo "[driver] built $DRIVER"
echo "Install with:  $0 install"
