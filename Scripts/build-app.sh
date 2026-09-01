#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Reed.app"
CONTENTS="$APP/Contents"

swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN/Reed" "$CONTENTS/MacOS/Reed"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# SwiftPM emits dependency resources as .bundle directories next to the binary.
#
# FluidAudio's bundle also carries its text-to-speech lexicon/pronunciation
# data (luxtts_en_us_*), which Reed's ASR-only usage never touches — an
# earlier version of this script stripped those files, saving ~1 MB on an
# ~18 MB app. That was reverted: it was verified by hand (a real
# transcription pass against the trimmed bundle) but nothing in CI exercises
# the *packaged* app, so a future FluidAudio release restructuring its
# resources could ship a silently broken bundle with no test to catch it —
# an unverified risk not worth carrying for 1 MB against a 600 MB model
# download. If bundle size becomes a real complaint, reintroduce the trim
# behind a CI step that runs a real transcription through the packaged
# .app, so it's a guarded optimization rather than a hopeful one.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$CONTENTS/Resources/"
done

for asset in Reed.icns start.aiff stop.aiff cancel.aiff; do
    [ -f "$ROOT/Resources/$asset" ] && cp "$ROOT/Resources/$asset" "$CONTENTS/Resources/"
done

# FluidAudio (Apache-2.0) and KeyboardShortcuts (MIT) are compiled into this
# binary — their licences must ship with it, not just live in the repo.
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$CONTENTS/Resources/THIRD_PARTY_LICENSES.md"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
