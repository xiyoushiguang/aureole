#!/bin/bash
# Builds Aureole.app (ad-hoc signed) into build/. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="$(cat VERSION)"
BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
swift build -c "$CONFIG" --product Aureole
BIN=".build/$CONFIG/Aureole"
APP="build/Aureole.app"
mkdir -p build
# Move any previous bundle aside instead of deleting it in place.
if [ -e "$APP" ]; then mv "$APP" "$(mktemp -d "${TMPDIR:-/tmp}/aureole-stale.XXXXXX")/"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aureole"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NO/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# Ad-hoc signature by default. Set CODESIGN_IDENTITY to a Developer ID for notarized releases.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier app.aureole.Aureole "$APP"
echo "Built $APP (v$VERSION build $BUILD_NO, $CONFIG)"
