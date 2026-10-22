#!/bin/sh
# Builds build/MacArch.app.
#
#   tests/scripts/build-app.sh            ad-hoc signed, this Mac's architecture
#   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: ..." tests/scripts/build-app.sh
#
# With a signing identity, everything is signed for notarisation: hardened
# runtime and secure timestamps, inside out (scripts/release.sh does this).
# The app carries macarch-mcp and macarch-cli, so an installed copy works
# with `claude mcp add macarch -- /Applications/MacArch.app/Contents/MacOS/macarch-mcp --attach`.
set -e
cd "$(dirname "$0")/../.."

if [ -n "$UNIVERSAL" ]; then
    ARCHS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCHS --product MacArch
swift build -c release $ARCHS --product macarch-mcp
swift build -c release $ARCHS --product macarch-cli
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=build/MacArch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacArch" "$BIN/macarch-mcp" "$BIN/macarch-cli" "$APP/Contents/MacOS/"
cp Apps/MacArch/Info.plist "$APP/Contents/Info.plist"
# The icon: Icon Composer's AppIcon.icon (layers drawn by Tools/icon/draw.py),
# compiled to Assets.car and AppIcon.icns.
xcrun actool Apps/MacArch/Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist build/AppIcon-partial.plist > /dev/null
rm -f build/AppIcon-partial.plist

if [ -n "$VERSION" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD_NUMBER" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    OPTIONS="--timestamp=none"
else
    OPTIONS="--options runtime --timestamp"
fi
sign() {
    codesign --force $OPTIONS --sign "$IDENTITY" "$@"
}
sign "$APP/Contents/MacOS/macarch-mcp"
sign "$APP/Contents/MacOS/macarch-cli"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
