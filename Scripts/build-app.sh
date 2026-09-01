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
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    dest="$CONTENTS/Resources/$(basename "$bundle")"
    cp -R "$bundle" "$dest"

    # FluidAudio's resource bundle carries LuxTTS lexicon/pronunciation data
    # (luxtts_en_us_*) used only by its text-to-speech path. Reed is ASR-only
    # (AsrManager/Parakeet) and never constructs LuxTtsG2p, so these files are
    # dead weight — drop them, and the bundle itself if that empties it.
    find "$dest" -type f -iname 'luxtts_*' -delete
    find "$dest" -type d -empty -delete
done

for asset in Reed.icns start.aiff stop.aiff cancel.aiff; do
    [ -f "$ROOT/Resources/$asset" ] && cp "$ROOT/Resources/$asset" "$CONTENTS/Resources/"
done

codesign --force --deep --sign - "$APP"
echo "Built $APP"
