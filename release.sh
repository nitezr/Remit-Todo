#!/bin/bash
# Builds a release Remit.app and packages it as a DMG in dist/.
#
# Deliberately separate from run.sh: that one builds debug and launches straight into the dev
# loop, this one produces the artifact you'd actually hand to someone (or reinstall from after
# wiping a machine). Both wrap the SPM binary in a real .app because a bare executable gets no
# stable TCC identity, and Reminders access is granted to that identity.
#
# Usage:
#   ./release.sh                 version from `git describe`, or 0.0.0-dev
#   ./release.sh 0.2.0           explicit version
#   ./release.sh 0.2.0 --install also install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ] || [ "$VERSION" = "--install" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev")"
fi
VERSION="${VERSION#v}"                       # accept both 0.2.0 and v0.2.0
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
INSTALL=false
for arg in "$@"; do [ "$arg" = "--install" ] && INSTALL=true; done

STAGING=".build/dmg-staging"
APP="$STAGING/Remit.app"
DIST="dist"
DMG="$DIST/Remit-$VERSION.dmg"

echo "==> Building Remit $VERSION (build $BUILD_NUMBER) in release configuration"
swift build -c release

echo "==> Assembling app bundle"
rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$DIST"
cp Sources/Remit/Supporting/Info.plist "$APP/Contents/Info.plist"
cp .build/release/Remit "$APP/Contents/MacOS/Remit"

# Stamp the real version rather than shipping the placeholder from the source plist. CFBundleVersion
# must increase monotonically for Sparkle and for macOS's own "newer version installed" checks, so
# it is the commit count rather than the marketing version.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Signing. A Developer ID is used when one exists; otherwise the bundle is ad-hoc signed, which is
# enough for the app to run locally and to hold its Reminders permission, but NOT enough for
# Gatekeeper to accept it after the file has been downloaded. See README "Distribution".
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
    echo "    (to notarize: xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait)"
    echo "    (then staple:  xcrun stapler staple \"$DMG\")"
else
    echo "==> No Developer ID found; ad-hoc signing"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Building DMG"
# A symlink to /Applications is the whole drag-and-drop install convention; without it the DMG
# opens to a lone app icon and people run it from the mounted image, where it cannot update.
ln -sf /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create \
    -volname "Remit $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

codesign --force --sign "${IDENTITY:--}" "$DMG" 2>/dev/null || true

if [ "$INSTALL" = true ]; then
    echo "==> Installing to /Applications"
# Anchored: the unanchored pattern also matched /Applications/Glaze/Remit.app, so every
# run silently killed the old Electron build the user still had open.
    pkill -f "^/Applications/Remit.app/Contents/MacOS/Remit" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Remit.app
    cp -R "$APP" /Applications/Remit.app
    open /Applications/Remit.app
fi

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
if [ -z "$IDENTITY" ]; then
    echo
    echo "This DMG is ad-hoc signed, not notarized. On this machine it installs and runs fine."
    echo "On any machine that DOWNLOADS it, macOS will refuse it until the user either"
    echo "right-clicks the app and chooses Open, or runs:"
    echo "    xattr -dr com.apple.quarantine /Applications/Remit.app"
    echo "Notarization needs a paid Developer ID; see README \"Distribution\"."
fi
