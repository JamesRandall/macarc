#!/bin/sh
# Builds a signed, notarised MacArch release in build/releases/VERSION:
#   MacArch-VERSION.dmg   (stapled; drag MacArch to Applications)
#   MacArch-VERSION.zip   (the stapled app)
#
#   scripts/release.sh VERSION
#   NOTARISE=0 scripts/release.sh VERSION   no credentials: universal build and
#                                           DMG, signed with SIGN_IDENTITY (default
#                                           ad hoc), not notarised
#
# Needs APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID and CSC_NAME
# (the Developer ID Application identity, with or without that prefix), in
# the environment or in an env file: .env.local, or the file named by
# MACARCH_ENV_FILE. No ROMs are included: users supply their own.
set -e
cd "$(dirname "$0")/.."

VERSION=$1
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh VERSION" >&2; exit 2; }

ENV_FILE=${MACARCH_ENV_FILE:-.env.local}
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi
if [ "$NOTARISE" = "0" ]; then
    IDENTITY=${SIGN_IDENTITY:--}
else
    for name in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID CSC_NAME; do
        eval "value=\$$name"
        [ -n "$value" ] || { echo "release: $name isn't set" >&2; exit 1; }
    done
    case "$CSC_NAME" in
        "Developer ID Application:"*) IDENTITY=$CSC_NAME ;;
        *) IDENTITY="Developer ID Application: $CSC_NAME" ;;
    esac
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "release: warning: the working tree has uncommitted changes" >&2
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
export UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" VERSION BUILD_NUMBER
tests/scripts/build-app.sh

APP=build/MacArch.app
OUT=build/releases/$VERSION
rm -rf "$OUT"
mkdir -p "$OUT"

notarise() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" --wait
}

if [ "$NOTARISE" != "0" ]; then
    echo "Notarising the app..."
    ditto -c -k --keepParent "$APP" "$OUT/notarise.zip"
    notarise "$OUT/notarise.zip"
    rm "$OUT/notarise.zip"
    xcrun stapler staple "$APP"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/MacArch-$VERSION.zip"

echo "Making the disk image..."
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/MacArch.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUT/MacArch-$VERSION.dmg"
hdiutil create -quiet -volname "MacArch $VERSION" -srcfolder "$STAGING" -format UDZO "$DMG"
rm -rf "$STAGING"
if [ "$NOTARISE" = "0" ]; then
    echo "Built $OUT (not notarised: Gatekeeper will ask before first launch)"
    exit 0
fi
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarise "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
echo "Built $OUT"
