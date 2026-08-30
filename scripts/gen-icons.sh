#!/bin/sh
# Renders the claw SVGs to the PNGs that internal/icon embeds, and builds the app icon.
#
# The PNGs are committed, so this only runs when the art changes. A contributor without
# rsvg-convert can still build v-claw.
set -eu

cd "$(dirname "$0")/.."
SRC=resources/icons
OUT=internal/icon/png

command -v rsvg-convert >/dev/null || {
	echo "gen-icons: rsvg-convert not found; PNGs are committed, skipping" >&2
	exit 0
}

mkdir -p "$OUT"

# Menu bar template images. @2x carries Retina; macOS picks by suffix.
for s in off armed active basic overridden; do
	rsvg-convert -w 18 -h 18 "$SRC/$s.svg" -o "$OUT/$s.png"
	rsvg-convert -w 36 -h 36 "$SRC/$s.svg" -o "$OUT/$s@2x.png"
done

# App icon, full colour. The claw is orange, after the printed part it is named for.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ICONSET=$TMP/AppIcon.iconset
mkdir -p "$ICONSET"

ORANGE=$TMP/orange.svg
sed -e 's/#000/#F26722/g' -e 's/width="18" height="18"/width="1024" height="1024"/' \
	"$SRC/active.svg" >"$ORANGE"

for px in 16 32 64 128 256 512 1024; do
	rsvg-convert -w $px -h $px "$ORANGE" -o "$ICONSET/icon_${px}x${px}.png"
done
# iconutil wants specific names; map the ones it requires.
mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
rm -f "$ICONSET/icon_64x64.png"

iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
echo "gen-icons: wrote $OUT/*.png and $SRC/AppIcon.icns"
