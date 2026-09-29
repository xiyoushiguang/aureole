#!/bin/bash
# Packages a release build into dist/Aureole-<version>.zip and .dmg, each with a .sha256.
# Usage: scripts/package.sh
# Signing follows scripts/build-app.sh: ad-hoc unless CODESIGN_IDENTITY is set. No notarization here.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
NAME="Aureole-$VERSION"
DIST="dist"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aureole-package.XXXXXX")"

# Build into a scratch dir so a running build/Aureole.app is never touched.
OUT_DIR="$WORK/stage" scripts/build-app.sh release
APP="$WORK/stage/Aureole.app"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
# Move any previous artifacts of this version aside instead of deleting them in place.
for f in "$DIST/$NAME.zip" "$DIST/$NAME.dmg" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.dmg.sha256"; do
    if [ -e "$f" ]; then mv "$f" "$(mktemp -d "${TMPDIR:-/tmp}/aureole-stale.XXXXXX")/"; fi
done

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# DMG: the app next to a shortcut to /Applications.
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Aureole.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "Aureole $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then codesign --force --sign "$CODESIGN_IDENTITY" "$DIST/$NAME.dmg"; fi

(
    cd "$DIST"
    shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256"
    shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256"
    cat "$NAME.zip.sha256" "$NAME.dmg.sha256"
)
echo "Packaged $DIST/$NAME.zip and $DIST/$NAME.dmg"
