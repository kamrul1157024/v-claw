#!/bin/sh
# Renders one state of the v-claw glyph: a hand, plus a status dot.
#
# The hand never changes shape, so the mark stays recognisable. State lives in the dot,
# and in the hand being greyed out when v-claw is doing nothing.
#
# usage: gen.sh <outfile> <hand-colour> <dot-colour> <solid|hollow|slash>
set -eu
out=$1 hand=$2 dot=$3 style=$4

case $style in
plain)  D="" ;;
hollow) D="<circle cx=\"13.9\" cy=\"13.9\" r=\"2.9\" fill=\"none\" stroke=\"$dot\" stroke-width=\"1.9\"/>" ;;
solid)  D="<circle cx=\"13.9\" cy=\"13.9\" r=\"3.6\" fill=\"$dot\"/>" ;;
slash)  D="<circle cx=\"13.9\" cy=\"13.9\" r=\"3.6\" fill=\"$dot\"/><path d=\"M 12.1 13.9 L 15.7 13.9\" stroke=\"#fff\" stroke-width=\"1.5\" stroke-linecap=\"round\"/>" ;;
esac

# The app icon has no badge, so it must not carry the gap either.
GAP=4.9
[ "$style" = plain ] && GAP=0

# The mask punches a gap around the dot so it reads as a separate badge rather than a
# blob merged into the palm.
cat >"$out" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18">
  <mask id="badge">
    <rect width="18" height="18" fill="#fff"/>
    <circle cx="13.9" cy="13.9" r="$GAP" fill="#000"/>
  </mask>
  <g mask="url(#badge)">
    <g stroke="$hand" stroke-width="2.3" stroke-linecap="round" fill="none">
      <path d="M 4.2 9.4 L 4.2 4.5"/>
      <path d="M 7.3 9.4 L 7.3 2.5"/>
      <path d="M 10.4 9.4 L 10.4 4.1"/>
      <path d="M 2.7 10.9 L 1.5 7.9"/>
    </g>
    <rect x="2.5" y="8.7" width="9.4" height="5.7" rx="2.4" fill="$hand"/>
  </g>
  $D
</svg>
EOF
