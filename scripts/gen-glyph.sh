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
hollow) D="<circle cx=\"14.4\" cy=\"14.4\" r=\"2.7\" fill=\"none\" stroke=\"$dot\" stroke-width=\"1.9\"/>" ;;
solid)  D="<circle cx=\"14.4\" cy=\"14.4\" r=\"3.4\" fill=\"$dot\"/>" ;;
slash)  D="<circle cx=\"14.4\" cy=\"14.4\" r=\"3.4\" fill=\"$dot\"/><path d=\"M 12.7 14.4 L 16.1 14.4\" stroke=\"#fff\" stroke-width=\"1.4\" stroke-linecap=\"round\"/>" ;;
esac

# The app icon has no badge, so it must not carry the gap either.
GAP=4.6
[ "$style" = plain ] && GAP=0

# The mask punches a gap around the dot so it reads as a separate badge rather than a
# blob merged into the palm.
cat >"$out" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18">
  <mask id="badge">
    <rect width="18" height="18" fill="#fff"/>
    <circle cx="14.4" cy="14.4" r="$GAP" fill="#000"/>
  </mask>
  <g mask="url(#badge)">
    <g stroke="$hand" stroke-width="2.5" stroke-linecap="round" fill="none">
      <path d="M 3.5 10.0 L 3.5 3.3"/>
      <path d="M 6.9 10.0 L 6.9 1.5"/>
      <path d="M 10.3 10.0 L 10.3 2.9"/>
      <path d="M 2.0 11.8 L 0.9 8.4"/>
    </g>
    <rect x="1.8" y="9.1" width="10.7" height="6.6" rx="2.9" fill="$hand"/>
  </g>
  $D
</svg>
EOF
