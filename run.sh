#!/bin/bash
# Builds Remit and launches it as a real .app bundle.
#
# A bare SPM executable has no bundle, so macOS gives it no Dock icon and won't reliably
# activate or show its window -- especially when launched from a script. Wrapping the binary
# in a minimal .app fixes activation, gives it a stable TCC identity for the Reminders
# permission, and makes ⌘-Tab work.
set -e
cd "$(dirname "$0")"

swift build
APP=".build/Remit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Sources/Remit/Supporting/Info.plist "$APP/Contents/Info.plist"
cp .build/debug/Remit "$APP/Contents/MacOS/Remit"
# Ship the CLI inside the bundle so Settings -> Automation has a stable path to point at, and so
# installing the app installs the automation tool with it.
cp .build/debug/remit-cli "$APP/Contents/MacOS/remit-cli"
# Prefer the stable local identity if ./setup-signing.sh has been run: an ad-hoc signature
# changes with every code change, and macOS revokes the Reminders grant when it does.
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Remit Development"; then
    SIGN_ID="Remit Development"
fi
codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null || true

# --install copies the bundle to /Applications so Remit shows up in Launchpad and Spotlight
# like a normal app. Note that macOS ties the Reminders permission to the bundle's location, so
# the installed copy asks for access once on its own; and it is a copy, meaning a later
# `./run.sh` alone updates only the dev build. Re-run with --install to update the installed one.
if [ "$1" = "--install" ]; then
    rm -rf /Applications/Remit.app
    cp -R "$APP" /Applications/Remit.app
    # Anchored: the unanchored pattern also matched /Applications/Glaze/Remit.app, so every
    # run silently killed the old Electron build the user still had open.
    pkill -f "^/Applications/Remit.app/Contents/MacOS/Remit" 2>/dev/null || true
    sleep 1
    open /Applications/Remit.app
    echo "installed and launched /Applications/Remit.app"
    exit 0
fi

# Once Remit is installed, keep the installed copy up to date automatically. Otherwise a plain
# ./run.sh would refresh only the dev bundle while the user tests the stale one in /Applications
# -- which looks exactly like a fix that didn't work.
if [ -d /Applications/Remit.app ]; then
    rm -rf /Applications/Remit.app
    cp -R "$APP" /Applications/Remit.app
    APP=/Applications/Remit.app
fi

# Anchored: the unanchored pattern also matched /Applications/Glaze/Remit.app, so every
# run silently killed the old Electron build the user still had open.
pkill -f "^/Applications/Remit.app/Contents/MacOS/Remit" 2>/dev/null || true
pkill -f "^\.build/debug/Remit" 2>/dev/null || true
sleep 1
open "$APP"
echo "launched $APP"
