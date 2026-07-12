#!/usr/bin/env bash
# Build XVC Live Mic into a runnable .app bundle.
#
#   ./build-app.sh          build build/XVC Live Mic.app
#   ./build-app.sh run      build, then launch it
#
# The bundle carries the Info.plist the raw SPM executable can't: LSUIElement (menu-bar
# only, no Dock icon) and NSMicrophoneUsageDescription (required for the mic TCC prompt).
# Ad-hoc signed — enough to run locally and request mic access. Distribution needs a
# Developer ID cert + notarization (docs/MAC_APP.md §2), and the .pkg installer (Phase 4).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/XVC Live Mic.app"
BUNDLE_ID=se.kth.xvclivemic
VERSION=0.1.0

echo "[app] building release ..."
swift build -c release --product XVCLiveMic 2>&1 | tail -2
BIN="$(swift build -c release --product XVCLiveMic --show-bin-path)/XVCLiveMic"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XVCLiveMic"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>XVC Live Mic</string>
    <key>CFBundleDisplayName</key>       <string>XVC Live Mic</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>XVCLiveMic</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>XVC Live Mic captures your microphone so it can stream your converted voice into the XVC Mic device.</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Mic-permission (TCC) keys off bundle id + signature; a rebuild with a
# fresh ad-hoc signature can re-prompt for the mic, which is fine for dev.
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --verbose=1 "$APP" >/dev/null && echo "[app] signature valid"

echo "[app] built $APP"
if [ "${1:-}" = "run" ]; then
    echo "[app] launching (look for the mic icon in the menu bar) ..."
    open "$APP"
fi
