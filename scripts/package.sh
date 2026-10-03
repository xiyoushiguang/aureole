#!/bin/bash
# Packages a release build into dist/Aureole-<version>.zip and .dmg, each with a .sha256.
# Usage: scripts/package.sh
# Signing follows scripts/build-app.sh: ad-hoc unless CODESIGN_IDENTITY is set.
# Notarized release: CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=aureole scripts/package.sh
# (NOTARY_PROFILE is a keychain profile made once with `xcrun notarytool store-credentials`.)
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

notarize() {   # notarize <file>: submit, then poll; a flaky network while waiting is retried, not fatal
    local out id status tries=0
    out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)" || { echo "$out"; exit 1; }
    id="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" || { echo "$out"; exit 1; }
    echo "submitted $1 as $id"
    local fails=0 err
    while :; do
        err="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)" \
            && status="$(echo "$err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)" \
            || status=""
        case "$status" in
            Accepted) echo "notarized: $1"; return 0 ;;
            Invalid|Rejected)
                echo "Notarization $status for $1:"; xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"; exit 1 ;;
            "") fails=$((fails + 1))
                # A dropped connection is worth retrying; a missing credential is not.
                if echo "$err" | grep -q "No Keychain password item"; then echo "$err"; exit 1; fi
                [ "$fails" -ge 10 ] && { echo "notarytool keeps failing:"; echo "$err"; exit 1; }
                sleep 30 ;;
            *) fails=0; tries=$((tries + 1))
               [ "$tries" -gt 240 ] && { echo "gave up waiting on $id (check: xcrun notarytool info $id)"; exit 1; }
               sleep 30 ;;
        esac
    done
}
NOTARIZE=0
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARIZE=1
    # The app is notarized from a zip, then the ticket is stapled so it opens offline too.
    ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
    notarize "$WORK/notarize.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "warning: signed but not notarized (set NOTARY_PROFILE to notarize)"
fi

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
if [ -n "${CODESIGN_IDENTITY:-}" ]; then codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DIST/$NAME.dmg"; fi
if [ "$NOTARIZE" = 1 ]; then
    notarize "$DIST/$NAME.dmg"
    xcrun stapler staple "$DIST/$NAME.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DIST/$NAME.dmg"
fi

(
    cd "$DIST"
    shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256"
    shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256"
    cat "$NAME.zip.sha256" "$NAME.dmg.sha256"
)
echo "Packaged $DIST/$NAME.zip and $DIST/$NAME.dmg"
