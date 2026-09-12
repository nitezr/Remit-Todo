#!/bin/bash
# Removes Remit from this Mac, so the next install starts again from the welcome tour.
#
# Everything is moved to the Trash rather than deleted, so a mistake can be undone from there.
# Your tasks, lists, tags and sections live in Apple Reminders and are not touched.
set -u

BUNDLE_ID="com.nitesh.remit"
STAMP="$(date +%Y%m%d-%H%M%S)"

to_trash() {
    [ -e "$1" ] || return 0
    mv "$1" "$HOME/.Trash/$(basename "$1")-$STAMP" && echo "Moved to Trash: $1"
}

# Quit Remit first, or it rewrites its files on the way out.
if pkill -f "^/Applications/Remit.app/Contents/MacOS/Remit" 2>/dev/null; then
    sleep 1
fi

to_trash "/Applications/Remit.app"
to_trash "$HOME/Library/Application Support/Remit"
to_trash "/tmp/remit-debug.log"

if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    defaults delete "$BUNDLE_ID" && echo "Cleared preferences ($BUNDLE_ID)"
fi

# Forget the permissions too, so first launch asks for them again the way a new user sees it.
tccutil reset Reminders "$BUNDLE_ID" >/dev/null 2>&1 && echo "Reset Reminders access"
tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" >/dev/null 2>&1 && echo "Reset Full Disk Access"

echo "Remit is removed. Your Apple Reminders data is untouched."
