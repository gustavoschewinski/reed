#!/usr/bin/env bash
set -euo pipefail

# Builds Reed and installs it as the copy you actually run: /Applications.
#
# `build-app.sh` alone leaves `build/Reed.app`, which is fine for a smoke
# test and a trap for anything longer. Two copies of the same bundle
# identifier end up on disk, both get registered with LaunchServices, and
# launching the wrong one means debugging a binary that isn't the source you
# are reading. This script makes /Applications the only copy worth running
# and tells the rest of macOS about it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/Reed.app"
DEST="/Applications/Reed.app"
BUNDLE_ID="com.gustavoschewinski.reed"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_IMPORTER="/System/Library/Spotlight/Application.mdimporter"

"$ROOT/Scripts/build-app.sh"

# Ask Reed to quit; don't kill it.
#
# A normal Quit is the one code path that restores the machine's output
# volume — `AppDelegate.applicationWillTerminate` unwinds the mute that
# dictation applies. A SIGTERM skips it, so killing Reed mid-recording can
# leave the Mac silent with nothing on screen to explain why. `pkill` stays
# as the fallback for a copy that never answers the Apple event, and the
# pattern matches every copy, not just the installed one: a stray
# `build/Reed.app` holds the same hotkey and would otherwise survive the
# install and keep answering it.
if pgrep -f "Reed.app/Contents/MacOS/Reed" >/dev/null; then
    echo "Quitting the running Reed…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 20); do
        pgrep -f "Reed.app/Contents/MacOS/Reed" >/dev/null || break
        sleep 0.25
    done
    if pgrep -f "Reed.app/Contents/MacOS/Reed" >/dev/null; then
        echo "It didn't answer the quit event; killing it." >&2
        pkill -f "Reed.app/Contents/MacOS/Reed" || true
        sleep 1
    fi
fi

# This is the only place in the repo that deletes a directory outside it, so
# it checks what it is about to delete rather than trusting the path.
if [ -e "$DEST" ]; then
    installed_id="$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    if [ "$installed_id" != "$BUNDLE_ID" ]; then
        echo "Refusing to replace $DEST: not a Reed bundle (identifier: ${installed_id:-none})." >&2
        exit 1
    fi
    rm -rf "$DEST"
fi

# Replaced wholesale rather than copied over: a bundle that has lost a file
# between versions would otherwise keep it forever, and the leftover is
# signed by nothing.
cp -R "$SRC" "$DEST"

# `cp` moves bytes and tells nobody. LaunchServices still holds the record
# for the bundle that was there before — same identifier, older path
# contents — and it is what the Finder, `open -a` and the login item all
# resolve through.
"$LSREGISTER" -f -R "$DEST"

# Drop the dev copy's record so one identifier resolves to one bundle. It
# comes back on its own the next time that copy is launched; the point is
# that nothing resolves to it in the meantime.
[ -e "$SRC" ] && "$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true

# Spotlight does not notice a locally built app on its own, and Reed needs it
# more than most apps do: it runs `.accessory` with no Dock icon, so ⌘-Space
# is the only way to open it. Without this the app is genuinely unreachable —
# not in search, not in the Dock, nowhere.
#
# `-r` asks the Spotlight *server* to reimport everything the application
# importer claims. That indirection is the point: the server is privileged,
# so this lands even when the caller has no Full Disk Access, which a plain
# `mdimport` on the bundle does not reliably do.
mdimport -r "$APP_IMPORTER"

open -a "$DEST"

echo "Installed $DEST and launched it."
echo "It has no Dock icon by design — it's the waveform in the menu bar, or ⌘-Space \"Reed\"."
