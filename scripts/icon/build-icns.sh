#!/bin/bash
# Builds Resources/AppIcon.icns from design/icon/j-limb.svg (+ the small-size variant).
# QuickLook (qlmanage) renders each SVG at 1024px, then make-iconset.swift clips the tile to a
# transparent background and resamples every iconset slot. Nothing beyond macOS is needed.
# Usage: scripts/icon/build-icns.sh
# Also writes design/icon/preview/*.png so the result can be checked by eye.
set -euo pipefail
cd "$(dirname "$0")/../.."

MAIN="design/icon/j-limb.svg"
SMALL="design/icon/j-limb-small.svg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aureole-icon.XXXXXX")"
ICONSET="$WORK/AppIcon.iconset"
PREVIEW="design/icon/preview"
mkdir -p "$PREVIEW"

render1024() { # render1024 <svg> <out.png>
  local dir="$WORK/ql-$RANDOM"
  mkdir -p "$dir"
  qlmanage -t -s 1024 -o "$dir" "$1" >/dev/null 2>&1 || true
  local made="$dir/$(basename "$1").png"
  [ -s "$made" ] || { echo "render failed: $1"; exit 1; }
  mv "$made" "$2"
}

render1024 "$MAIN" "$WORK/main.png"
render1024 "$SMALL" "$WORK/small.png"
swift scripts/icon/make-iconset.swift "$WORK/main.png" "$WORK/small.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

for px in 16 32 64 128 256 1024; do
  case $px in 16) src=icon_16x16;; 32) src=icon_32x32;; 64) src=icon_32x32@2x;; 128) src=icon_128x128;; 256) src=icon_256x256;; 1024) src=icon_512x512@2x;; esac
  cp "$ICONSET/$src.png" "$PREVIEW/$px.png"
done
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns and $PREVIEW/{16,32,64,128,256,1024}.png"
