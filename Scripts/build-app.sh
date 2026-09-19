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

# The version in the bundle comes from the tag being built, not from the
# checked-in Info.plist: that file would otherwise have to be edited in
# lockstep with every tag, and forgetting means a release that reports the
# previous version in About and to Homebrew. `REED_VERSION` is what the
# release workflow passes; a local build falls back to the newest tag, and
# then to whatever the plist already says.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
VERSION="${REED_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
fi
VERSION="${VERSION#v}"
VERSION="${VERSION:-$PLIST_VERSION}"

# CFBundleVersion has to increase for every build macOS is asked to compare,
# so it carries the commit count rather than a constant 1.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"

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

# A stable identity keeps permission grants across rebuilds; ad-hoc ("-")
# changes every build and revokes them. Scripts/dev-cert.sh creates one.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Reed Dev Signing"; then
    IDENTITY="Reed Dev Signing"
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
