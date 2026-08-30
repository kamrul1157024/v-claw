#!/bin/sh
# Regenerates every icon from scratch: the state SVGs, the menu bar PNGs that
# internal/icon embeds, the docs strip, and the app icon.
#
# The menu bar icon is colour, not a macOS template image. A template gets tinted black
# or white by the system, which would throw away the status colour. Orange reads on both
# light and dark menu bars, so the usual reason to prefer a template does not apply.
#
# Outputs are committed, so this only runs when the art changes. A contributor without
# rsvg-convert can still build v-claw.
set -eu

cd "$(dirname "$0")/.."
SRC=resources/icons
OUT=internal/icon/png

command -v rsvg-convert >/dev/null || {
	echo "gen-icons: rsvg-convert not found; icons are committed, skipping" >&2
	exit 0
}

ORANGE='#F26722' # claw orange, after the printed part v-claw is named for
GREY='#8E8E93'   # inactive
GREEN='#34C759'  # holding, guaranteed
AMBER='#F5A623'  # waiting, or holding without a guarantee
RED='#FF3B30'    # something is overriding v-claw

# The hand never changes shape, so the mark stays recognisable at a glance. State lives
# in the badge, and in the hand going grey when v-claw is doing nothing.
#            file          hand      badge     style
sh scripts/gen-glyph.sh "$SRC/off.svg" "$GREY" "$GREY" solid
sh scripts/gen-glyph.sh "$SRC/armed.svg" "$ORANGE" "$AMBER" hollow
sh scripts/gen-glyph.sh "$SRC/active.svg" "$ORANGE" "$GREEN" solid
sh scripts/gen-glyph.sh "$SRC/basic.svg" "$ORANGE" "$AMBER" solid
sh scripts/gen-glyph.sh "$SRC/overridden.svg" "$ORANGE" "$RED" slash
sh scripts/gen-glyph.sh "$SRC/app.svg" "$ORANGE" "$ORANGE" plain

STATES='off armed active basic overridden'

mkdir -p "$OUT"
for s in $STATES; do
	rsvg-convert -w 18 -h 18 "$SRC/$s.svg" -o "$OUT/$s.png"
	rsvg-convert -w 36 -h 36 "$SRC/$s.svg" -o "$OUT/$s@2x.png"
done

# Docs strip, at a size that reads on a web page.
mkdir -p docs/images
rsvg-convert -w 500 -h 100 -o docs/images/states.png /dev/stdin <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 90 18" width="500" height="100">
$(i=0; for s in $STATES; do
	printf '<g transform="translate(%d,0)">%s</g>' "$i" "$(sed '1d;$d' "$SRC/$s.svg")"
	i=$((i + 18))
done)
</svg>
EOF

# App icon: the hand alone, no status badge.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ICONSET=$TMP/AppIcon.iconset
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512 1024; do
	rsvg-convert -w $px -h $px "$SRC/app.svg" -o "$ICONSET/icon_${px}x${px}.png"
done
mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
rm -f "$ICONSET/icon_64x64.png"

iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
echo "gen-icons: wrote $SRC/*.svg, $OUT/*.png, docs/images/states.png, $SRC/AppIcon.icns"
