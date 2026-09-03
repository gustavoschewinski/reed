#!/usr/bin/env bash
# Regenerates Resources/Reed.icns from Resources/icon-source.png.
#
# The design is the waveform — the same five bars the overlay draws while
# you dictate — in white on Reed's red. It is the app's one colour used at
# its largest: `Theme.Window.mark` is that red spent once in the window, and
# this is the same idea at Dock size.
#
# The source is a raster, not the inline SVG this script used to carry. That
# is a real loss — the previous design could be edited by changing a path in
# this file — so the source lives in the repo as `Resources/icon-source.png`
# rather than only in whatever tool drew it. Replacing the icon means
# replacing that file and re-running this script.
#
# ---------------------------------------------------------------------------
# Why the art is rendered edge to edge
#
# The obvious thing to do is what Apple's own grid says: seat the rounded
# square in about 80% of the canvas and leave the rest as breathing room.
# Doing that produced a white box around the icon on macOS 26.
#
# Reed is built against the macOS 26 SDK, which opts the app into Tahoe's
# icon system: the system applies its own rounded-square shape and its own
# shadow. Handing it art that only covers part of the canvas makes it treat
# that art as a small legacy icon and mount it on the default light tile —
# the icon shrinks, and the tile shows around it as white. (Verified against
# Obsidian, which shows no tile: same icns-only packaging, but built against
# the 15.1 SDK, so it is drawn as-is.)
#
# So the art fills the canvas. The source's own drop shadow is cropped away
# with it — the system draws the shadow now, and keeping a second one baked
# into the art would double it.
#
# The corners are still rounded here even though macOS 26 masks them anyway.
# That mask is what older macOS does not do: the deployment floor is 14, and
# there a fully square icns renders as a hard square in the Dock. Rounding
# costs nothing on 26 (the system's mask lands on top of an identical curve)
# and is the whole difference on 14 and 15.
# ---------------------------------------------------------------------------
#
# Requires ImageMagick (`brew install imagemagick`) to rasterize and
# `iconutil` (part of the Xcode command line tools) to assemble the .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/icon-source.png"
OUT="$ROOT/Resources/Reed.icns"

CANVAS=1024
# 0.225 of the side — Apple's own corner radius for a macOS icon, which is
# 185.4pt on the 824pt square their template draws.
RADIUS=230

if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick's 'magick' command is required (brew install imagemagick)" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The bounding box of what is *solidly* opaque. Thresholding the alpha at
# 90% first is what excludes the source's soft drop shadow: a plain `-trim`
# would include it and leave the square floating inside its own shadow's
# box, off-centre and too small.
BOX="$(magick "$SRC" -alpha extract -threshold 90% -format '%@' info:)"
BOX_W="${BOX%%x*}"
BOX_REST="${BOX#*x}"
BOX_H="${BOX_REST%%+*}"
SQUARE=$(( BOX_W > BOX_H ? BOX_W : BOX_H ))

# The art's average colour, used to fill the source's own rounded corners
# and any padding needed to square the crop. Every pixel it fills is inside
# the corner radius that gets masked away below, so it is never seen — it
# exists so those pixels are opaque rather than transparent, which is what
# keeps the system from reading the icon as a partial-canvas legacy one.
FILL="$(magick "$SRC" -crop "$BOX" +repage -resize 1x1! -alpha off -format '#%[hex:p{0,0}]' info:)"

magick "$SRC" \
    -crop "$BOX" +repage \
    -background "$FILL" -alpha remove -alpha off \
    -gravity center -extent "${SQUARE}x${SQUARE}" \
    -resize "${CANVAS}x${CANVAS}!" \
    "$WORK/square.png"

magick "$WORK/square.png" \
    \( -size "${CANVAS}x${CANVAS}" xc:none \
       -fill white \
       -draw "roundrectangle 0,0 $((CANVAS - 1)),$((CANVAS - 1)) ${RADIUS},${RADIUS}" \) \
    -alpha off -compose CopyOpacity -composite \
    "$WORK/master.png"

ICONSET="$WORK/Reed.iconset"
mkdir -p "$ICONSET"

# Every size renders from the same master. The previous brass design needed
# a second, detail-free variant below 128px because its spine turned to mush
# at small sizes; five thick bars have no such detail to lose.
for size in 16 32 128 256 512; do
    magick "$WORK/master.png" -resize "${size}x${size}" "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    magick "$WORK/master.png" -resize "${double}x${double}" "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
