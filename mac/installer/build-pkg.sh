#!/usr/bin/env bash
# Build the one-download installer: app + "XVC Mic" driver in a single .pkg.
#
#   ./build-pkg.sh            build installer/build/XVCLiveMic-<ver>.pkg (unsigned/ad-hoc)
#
# Signing is driven by env, so CI can inject a Developer ID without changing this script:
#   APP_SIGN_ID="Developer ID Application: … (TEAMID)"   codesign the .app + driver
#   INSTALLER_SIGN_ID="Developer ID Installer: … (TEAMID)"   productsign the .pkg
#   NOTARY_PROFILE="xvc-notary"                          notarytool keychain profile
# Without them it builds an unsigned pkg that installs after a right-click-open / an
# allow in System Settings — fine for the team, not for public distribution.
set -euo pipefail

MAC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$MAC/installer"
OUT="$INST/build"
ROOT="$OUT/root"                       # payload staging: mirrors the install destinations
VERSION="${VERSION:-0.1.0}"
PKG_ID="se.kth.tmh.smfabrar"           # installer product identifier
PKG="$OUT/XVCLiveMic-$VERSION.pkg"

APP_SIGN_ID="${APP_SIGN_ID:-}"
INSTALLER_SIGN_ID="${INSTALLER_SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

rm -rf "$OUT"; mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL" "$OUT/scripts"

echo "[pkg] building the driver ..."
"$MAC/driver/build.sh" >/dev/null
cp -R "$MAC/driver/build/XVCMic.driver" "$ROOT/Library/Audio/Plug-Ins/HAL/"

echo "[pkg] building the app ..."
"$MAC/build-app.sh" >/dev/null
cp -R "$MAC/build/XVC Live Mic.app" "$ROOT/Applications/"

# Sign both with a real Developer ID if provided (driver + app must be signed for a
# distributable, notarizable pkg). Otherwise leave the ad-hoc signatures build-app.sh /
# driver/build.sh applied.
if [ -n "$APP_SIGN_ID" ]; then
    echo "[pkg] Developer ID signing app + driver ..."
    codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" \
        "$ROOT/Library/Audio/Plug-Ins/HAL/XVCMic.driver"
    codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" \
        "$ROOT/Applications/XVC Live Mic.app"
fi

cp "$INST/postinstall" "$OUT/scripts/postinstall"
chmod +x "$OUT/scripts/postinstall"

# One component pkg for the whole payload, with the coreaudiod-bounce postinstall.
#
# Bundle relocation MUST be off. pkgbuild marks .app bundles relocatable by default, so at
# install time macOS looks for an existing copy of the same bundle id anywhere on disk and
# installs over THAT instead of /Applications. Observed: it found a developer build in the
# source tree and installed there, leaving /Applications empty while still reporting
# success. --analyze gives us the component plist; force BundleIsRelocatable=false in it.
COMPONENT="$OUT/component.pkg"
PLIST="$OUT/component.plist"
pkgbuild --analyze --root "$ROOT" "$PLIST" >/dev/null
python3 - "$PLIST" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    comps = plistlib.load(f)
for c in comps:
    c["BundleIsRelocatable"] = False
with open(path, "wb") as f:
    plistlib.dump(comps, f)
PY
pkgbuild --root "$ROOT" \
         --component-plist "$PLIST" \
         --identifier "$PKG_ID" \
         --version "$VERSION" \
         --scripts "$OUT/scripts" \
         --install-location "/" \
         "$COMPONENT" >/dev/null

# Wrap in a product archive (gives the install UI + lets us productsign).
DISTRIB="$OUT/distribution.xml"
cat > "$DISTRIB" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>XVC Live Mic</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <pkg-ref id="$PKG_ID"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="XVC Live Mic"><pkg-ref id="$PKG_ID"/></choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

if [ -n "$INSTALLER_SIGN_ID" ]; then
    echo "[pkg] signing product with Developer ID Installer ..."
    productbuild --distribution "$DISTRIB" --package-path "$OUT" --sign "$INSTALLER_SIGN_ID" "$PKG"
else
    productbuild --distribution "$DISTRIB" --package-path "$OUT" "$PKG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    echo "[pkg] notarizing (this can take a few minutes) ..."
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
fi

rm -rf "$ROOT" "$OUT/scripts" "$COMPONENT" "$DISTRIB" "$PLIST"
echo "[pkg] built $PKG"
[ -n "$INSTALLER_SIGN_ID" ] && echo "[pkg] signed$([ -n "$NOTARY_PROFILE" ] && echo " + notarized")" || \
    echo "[pkg] UNSIGNED — installs via right-click Open, or set APP_SIGN_ID/INSTALLER_SIGN_ID"
