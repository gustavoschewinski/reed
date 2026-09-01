#!/usr/bin/env bash
# Builds Reed.app and packages it into a compressed, notarization-ready DMG
# at build/Reed.dmg — an /Applications shortcut alongside the app, the way
# every drag-to-install Mac app ships.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Reed.app"
DMG="$ROOT/build/Reed.dmg"

"$ROOT/Scripts/build-app.sh"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/Reed.app"
ln -s /Applications "$STAGE/Applications"

# Nothing destructive happens before this point: build-app.sh already
# succeeded and everything above only touches the temp staging directory.
rm -f "$DMG"
hdiutil create -volname Reed -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Wrote $DMG"
