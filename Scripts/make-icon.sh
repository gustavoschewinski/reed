#!/usr/bin/env bash
# Regenerates Resources/Reed.icns from the vector design below.
#
# The design is a cane reed — the blade that vibrates to give a clarinet or
# saxophone its voice — in brass (#C9A227) on a dark rounded-square ground.
# It has the three features that make a reed read as a reed rather than a
# leaf or a flame: a flat, square-cut base; an asymmetric taper (thick at
# the base, shaved to almost nothing at the tip); and a central spine.
#
# The spine disappears below 128px: at 16-64px it anti-aliases into the
# fill and just reads as mush, so those sizes render from a spine-free
# variant of the same silhouette instead of carrying a dead detail.
#
# Both variants are inline SVG so the icon has no opaque binary source;
# edit the paths here and re-run this script to change it.
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

# Shared blade silhouette: flat-cut base at y=820, near-parallel "heel" for
# the first ~160px, then a long asymmetric taper up to a near-point tip.
BLADE_PATH='M 424 820
            L 600 820
            C 600 764 596 706 588 656
            C 574 500 542 320 512 202
            C 482 320 450 500 436 656
            C 428 706 424 764 424 820
            Z'

cat > "$WORK/icon.svg" << EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="0" y="0" width="1024" height="1024" rx="184" ry="184" fill="#1C1C1E"/>
  <path d="$BLADE_PATH" fill="#C9A227"/>
  <path d="M 506 748 L 518 748 L 512 288 Z" fill="#8A6B12"/>
</svg>
EOF

cat > "$WORK/icon-small.svg" << EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="0" y="0" width="1024" height="1024" rx="184" ry="184" fill="#1C1C1E"/>
  <path d="$BLADE_PATH" fill="#C9A227"/>
</svg>
EOF

magick -background none "$WORK/icon.svg" -resize 1024x1024 "$WORK/master.png"
magick -background none "$WORK/icon-small.svg" -resize 1024x1024 "$WORK/master-small.png"

ICONSET="$WORK/Reed.iconset"
mkdir -p "$ICONSET"

# Below 128px the spine anti-aliases into mush — those sizes render from
# the spine-free master instead.
render() {
    local px="$1" name="$2"
    local source="$WORK/master.png"
    if [ "$px" -lt 128 ]; then
        source="$WORK/master-small.png"
    fi
    magick "$source" -resize "${px}x${px}" "$ICONSET/$name"
}

for size in 16 32 128 256 512; do
    render "$size" "icon_${size}x${size}.png"
    double=$((size * 2))
    render "$double" "icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
