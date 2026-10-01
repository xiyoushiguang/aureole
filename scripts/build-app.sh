#!/bin/bash
# Builds Aureole.app (ad-hoc signed) into build/. Usage: scripts/build-app.sh [debug|release]
# Set OUT_DIR to build the bundle somewhere else (scripts/package.sh does, to leave build/ alone).
# Set UNIVERSAL=1 for an arm64 + x86_64 binary (needs full Xcode; the Intel slice is untested).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
OUT_DIR="${OUT_DIR:-build}"
VERSION="$(cat VERSION)"
BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product Aureole
    swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product aureole-hook
    # Multi-arch builds go through Xcode's build system, which capitalises the configuration.
    case "$CONFIG" in debug) XC_CONFIG=Debug ;; *) XC_CONFIG=Release ;; esac
    BIN=".build/apple/Products/$XC_CONFIG/Aureole"
else
    swift build -c "$CONFIG" --product Aureole
    swift build -c "$CONFIG" --product aureole-hook
    BIN=".build/$CONFIG/Aureole"
fi
APP="$OUT_DIR/Aureole.app"
mkdir -p "$OUT_DIR"
# Move any previous bundle aside instead of deleting it in place.
if [ -e "$APP" ]; then mv "$APP" "$(mktemp -d "${TMPDIR:-/tmp}/aureole-stale.XXXXXX")/"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aureole"
# The hook helper ships beside the main binary; the app copies it to Application Support on launch.
cp "$(dirname "$BIN")/aureole-hook" "$APP/Contents/MacOS/aureole-hook"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NO/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# Ad-hoc signature by default. Set CODESIGN_IDENTITY to a Developer ID for notarized releases.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier app.aureole.Aureole "$APP"
echo "Built $APP (v$VERSION build $BUILD_NO, $CONFIG)"
