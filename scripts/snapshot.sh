#!/bin/bash
# Render the panel with sample data to PNG files (open panel, approval card, closed notch), in English and
# Chinese. Usage: scripts/snapshot.sh [out-dir]   (default build/snapshots). Compare two runs to see a change.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/snapshots}"
scripts/build-app.sh debug >/dev/null
build/Aureole.app/Contents/MacOS/Aureole --snapshot "$OUT"
build/Aureole.app/Contents/MacOS/Aureole --snapshot "$OUT" --lang zh
