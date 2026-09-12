#!/bin/bash
# Regenerates the README images from Remit's demo mode: made-up data, never your Reminders.
#
# Each shot launches Remit with --demo, lets it draw, has it save its own window as a PNG, and
# quits. Remit's window pops up briefly for each one; leave the mouse and keyboard alone while this
# runs, since quick add and the task panel need the window to keep focus.
#
# It builds its own bundle in .build/ with its own bundle identifier, so an installed Remit -- even
# a running one -- and its settings are left exactly as they are.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/images"
LOGS=".build/screenshot-logs"
# Name shots to regenerate only those, e.g. `scripts/screenshots.sh quick-add today-list`.
ONLY=" $* "
mkdir -p "$OUT" "$LOGS"

swift build -c release --product Remit
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=".build/RemitDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Sources/Remit/Supporting/Info.plist "$APP/Contents/Info.plist"
# A second copy of com.nitesh.remit is not activated and opens no window while the real one runs;
# a demo identifier also keeps the demo's preferences apart from the user's.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.nitesh.remit.demo" "$APP/Contents/Info.plist"
cp "$BIN_DIR/Remit" "$APP/Contents/MacOS/Remit"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
EXE_PATTERN="$PWD/$APP/Contents/MacOS/Remit"

shot() {
    local name="$1"; shift
    if [ "$ONLY" != "  " ] && [[ "$ONLY" != *" $name "* ]]; then return 0; fi
    local log="$PWD/$LOGS/$name.log" image="$PWD/$OUT/$name.png"
    echo "→ $name"
    rm -f "$image" "$log"
    # Every option takes a value, flags included (`--demo 1`). AppKit reads launch arguments as
    # name/value pairs; one bare flag shifts the rest, a stray word gets treated as a document to
    # open, and a launch that opens documents skips its first window.
    open -n "$APP" --args --demo 1 --snapshot "$image" --demo-log "$log" \
        -ApplePersistenceIgnoreState YES -onboarding.step 0 "$@"
    for _ in $(seq 1 40); do
        [ -f "$image" ] && break
        pgrep -f "^$EXE_PATTERN" >/dev/null || break
        perl -e 'select(undef,undef,undef,0.5)'
    done
    # Let the app finish quitting before the next launch.
    for _ in $(seq 1 10); do
        pgrep -f "^$EXE_PATTERN" >/dev/null || break
        perl -e 'select(undef,undef,undef,0.5)'
    done
    pkill -f "^$EXE_PATTERN" 2>/dev/null || true

    if [ ! -f "$image" ]; then
        echo "  failed: no image written. Remit said:" >&2
        cat "$log" >&2 2>/dev/null || echo "  (no log)" >&2
        return 1
    fi
    # Keep the repository light: 1800px wide is still sharp on a Retina README.
    local width
    width=$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')
    if [ "$width" -gt 1800 ]; then
        sips --resampleWidth 1800 "$image" >/dev/null
    fi
}

shot upcoming-board   --demo-view upcoming --demo-layout board --size 1440x900
shot today-list       --demo-view today --demo-layout list
shot calendar-month   --demo-view upcoming --demo-layout calendar --demo-range month --size 1440x900
shot project-sections --demo-view "project:🚀 Acme Launch" --demo-layout board --size 1440x900
shot quick-add        --demo-view "project:🚀 Acme Launch" --demo-layout list --demo-quick-add "Call Priya tomorrow 5pm p1 @Pri"
shot task-details     --demo-view today --demo-layout list --demo-peek "Finalize launch announcement copy"
shot filters-and-tags --demo-view tags
shot welcome-tour     --demo-view today --demo-layout list --demo-tour 1

echo "Images written to $OUT/"
