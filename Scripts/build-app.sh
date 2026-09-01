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
    [ -e "$bundle" ] && cp -R "$bundle" "$CONTENTS/Resources/"
done

for asset in Reed.icns start.aiff stop.aiff cancel.aiff; do
    [ -f "$ROOT/Resources/$asset" ] && cp "$ROOT/Resources/$asset" "$CONTENTS/Resources/"
done

codesign --force --deep --sign - "$APP"
echo "Built $APP"
