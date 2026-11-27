#!/bin/bash
# Draws the README's animation again, in English and Chinese, from the sample data: docs/demo.gif, docs/demo.zh.gif.
# The app draws the film frame by frame (--film --scene readme); scripts/readme-gif.py turns the frames into a GIF.
# Takes a few minutes: the card's shadow is slow to draw off screen. Needs Pillow and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT_DIR=build/readme-gif scripts/build-app.sh debug
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aureole-readme-gif.XXXXXX")"
build/readme-gif/Aureole.app/Contents/MacOS/Aureole --film "$WORK/en" --scene readme --lang en &
build/readme-gif/Aureole.app/Contents/MacOS/Aureole --film "$WORK/zh" --scene readme --lang zh
wait
python3 scripts/readme-gif.py "$WORK/en" docs/demo.gif
python3 scripts/readme-gif.py "$WORK/zh" docs/demo.zh.gif
echo "frames left in $WORK"
