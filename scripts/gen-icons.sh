#!/bin/sh
# Renders the claw SVGs to the PNGs that internal/icon embeds, and builds the app icon.
#
# The menu bar icon is colour, not a template image. A template would be tinted black or
# white by macOS and would lose the state signal that colour carries: grey for off,
# orange for holding, red for overridden. Shape still differs too, so the states stay
# distinguishable without relying on colour alone.
#
# The PNGs are committed, so this only runs when the art changes. A contributor without
# rsvg-convert can still build v-claw.
set -eu

cd "$(dirname "$0")/.."
SRC=resources/icons
OUT=internal/icon/png

# claw orange, after the printed part v-claw is named for
ORANGE='#F26722'
GREY='#8E8E93'
RED='#FF3B30'

command -v rsvg-convert >/dev/null || {
	echo "gen-icons: rsvg-convert not found; PNGs are committed, skipping" >&2
	exit 0
}

mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# state:colour
for pair in "off:$GREY" "armed:$ORANGE" "active:$ORANGE" "basic:$ORANGE" "overridden:$RED"; do
	s=${pair%%:*}
	c=${pair#*:}
	sed "s/#000/$c/g" "$SRC/$s.svg" >"$TMP/$s.svg"
	rsvg-convert -w 18 -h 18 "$TMP/$s.svg" -o "$OUT/$s.png"
	rsvg-convert -w 36 -h 36 "$TMP/$s.svg" -o "$OUT/$s@2x.png"
done

# Docs strip, at a size that reads on a web page.
rsvg-convert -w 400 -h 80 -o docs/images/states.png /dev/stdin <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 90 18" width="400" height="80">
$(i=0; for s in off armed active basic overridden; do
	printf '<g transform="translate(%d,0)">%s</g>' "$i" "$(sed '1d;$d' "$TMP/$s.svg")"
	i=$((i + 18))
done)
</svg>
EOF

# App icon.
ICONSET=$TMP/AppIcon.iconset
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512 1024; do
	rsvg-convert -w $px -h $px "$TMP/active.svg" -o "$ICONSET/icon_${px}x${px}.png"
done
mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
rm -f "$ICONSET/icon_64x64.png"

iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
echo "gen-icons: wrote $OUT/*.png, docs/images/states.png, $SRC/AppIcon.icns"
