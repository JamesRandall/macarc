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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/MacArch" "$BIN/macarch-mcp" "$BIN/macarch-cli" "$APP/Contents/MacOS/"
cp Apps/MacArch/Info.plist "$APP/Contents/Info.plist"
# The icon: Icon Composer's AppIcon.icon (layers drawn by Tools/icon/draw.py),
# compiled to Assets.car and AppIcon.icns.
# Absolute paths: actool hands the work to a long-lived helper, which
# resolves relative paths from wherever it was first started.
xcrun actool "$PWD/Apps/MacArch/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$PWD/build/AppIcon-partial.plist" > /dev/null
rm -f build/AppIcon-partial.plist
# The release notes, for Help > What's New.
cp WHATSNEW.md "$APP/Contents/Resources/WhatsNew.md"
# ditto keeps the framework's symlinks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

if [ -n "$VERSION" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD_NUMBER" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    # Ad hoc: no hardened runtime, whose library validation would reject
    # the (also ad hoc, so "different team") Sparkle framework.
    OPTIONS="--timestamp=none"
else
    OPTIONS="--options runtime --timestamp"
fi
sign() {
    codesign --force $OPTIONS --sign "$IDENTITY" "$@"
}
# Sparkle's helpers first (as Sparkle's documentation describes), then the
# framework, the tools and the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/MacOS/macarch-mcp"
sign "$APP/Contents/MacOS/macarch-cli"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
