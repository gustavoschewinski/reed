#!/usr/bin/env bash
# Regenerates Resources/Reed.icns from the vector design below.
#
# The design is a single brass (#C9A227) blade shape — the vibrating reed
# that gives a wind instrument its voice — on a dark rounded-square ground.
# It is defined inline as SVG so the icon has no opaque binary source; edit
# the path here and re-run this script to change it.
#
# Requires ImageMagick (`brew install imagemagick`) to rasterize the SVG,
# and `iconutil` (part of Xcode command line tools) to assemble the .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/Reed.icns"

if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick's 'magick' command is required (brew install imagemagick)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/icon.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="0" y="0" width="1024" height="1024" rx="184" ry="184" fill="#1C1C1E"/>
  <path d="M 512 176
           C 548 250 580 440 580 660
           C 580 748 555 824 512 824
           C 469 824 444 748 444 660
           C 444 440 476 250 512 176
           Z"
        fill="#C9A227"/>
</svg>
EOF

magick -background none "$WORK/icon.svg" -resize 1024x1024 "$WORK/master.png"

ICONSET="$WORK/Reed.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    magick "$WORK/master.png" -resize "${size}x${size}" "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    magick "$WORK/master.png" -resize "${double}x${double}" "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
