#!/bin/sh
# Builds a signed, notarised MacArch release in build/releases/VERSION:
#   MacArch-VERSION.dmg   (stapled; drag MacArch to Applications)
#   MacArch-VERSION.zip   (the stapled app, for Sparkle)
#   appcast.xml           (the update feed, including earlier releases)
#   notes.md              (this release's section of WHATSNEW.md)
#   linux/                LinuxArch's .deb packages for amd64 and arm64, and
#                         their notes (scripts/release-linux.sh, in Docker)
#
# WHATSNEW.md must have a "## VERSION" section: it becomes the GitHub
# release's notes, Sparkle's update window, and Help > What's New.
#
#   scripts/release.sh VERSION
#   scripts/release.sh VERSION --publish   ...then tag and make a GitHub release
#   NOTARISE=0 scripts/release.sh VERSION   no credentials: universal build and
#                                           DMG, signed with SIGN_IDENTITY (default
#                                           ad hoc), not notarised
#   LINUX=0 scripts/release.sh VERSION      without LinuxArch (no Docker needed)
#
# LinuxArch has the same version (LinuxArchApp.version) and its own notes
# (Apps/LinuxArch/WHATSNEW.md); its packages go on the same GitHub release,
# with its notes after MacArch's.
#
# Needs APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID and CSC_NAME
# (the Developer ID Application identity, with or without that prefix), in
# the environment or in an env file: .env.local, or the file named by
# MACARCH_ENV_FILE. The only ROM included is ArcLibre.
#
# The Sparkle signing key lives in the login keychain under the account
# "macarch"; create it once with:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account macarch
# Keep a backup: losing it means existing installs can't verify updates.
set -e
cd "$(dirname "$0")/.."

VERSION=$1
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh VERSION [--publish]" >&2; exit 2; }
PUBLISH=
[ "$2" = "--publish" ] && PUBLISH=1

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

# This release's notes: its section of WHATSNEW.md, without the heading.
NOTES=$(awk -v v="$VERSION" '
    /^<!--/ { comment = 1 } comment { if (/-->/) comment = 0; next }
    /^## / { on = ($2 == v); next }
    on' WHATSNEW.md | sed -e '/./,$!d')
[ -n "$NOTES" ] || { echo "release: WHATSNEW.md has no \"## $VERSION\" section" >&2; exit 1; }

REPO=JamesRandall/macarc
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
[ -x "$SPARKLE_BIN/generate_keys" ] || swift package resolve
# Unnotarised builds don't need a key (without one they don't check for updates).
if [ "$NOTARISE" != "0" ]; then
    SPARKLE_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account macarch -p) || {
        echo "release: no Sparkle key; run $SPARKLE_BIN/generate_keys --account macarch" >&2
        exit 1
    }
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "release: warning: the working tree has uncommitted changes" >&2
    [ -n "$PUBLISH" ] && { echo "release: commit them before publishing" >&2; exit 1; }
fi

OUT=build/releases/$VERSION
rm -rf "$OUT"
mkdir -p "$OUT/sparkle"
printf '%s\n' "$NOTES" > "$OUT/notes.md"

# LinuxArch first: it's the likelier to fail, and doesn't need notarising.
if [ "$LINUX" != "0" ]; then
    LINUX_VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Apps/LinuxArch/Sources/LinuxArchApp.swift)
    [ "$LINUX_VERSION" = "$VERSION" ] || {
        echo "release: LinuxArch is version $LINUX_VERSION (LinuxArchApp.version), not $VERSION" >&2
        exit 1
    }
    scripts/release-linux.sh "$OUT/linux"
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
export UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" VERSION BUILD_NUMBER SPARKLE_PUBLIC_KEY
tests/scripts/build-app.sh

APP=build/MacArch.app

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
ZIP="$OUT/MacArch-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

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

echo "Making the appcast..."
# Start from the published feed so earlier releases stay listed.
gh release download --repo "$REPO" --pattern appcast.xml --dir "$OUT/sparkle" 2>/dev/null || true
cp "$ZIP" "$OUT/sparkle/"
# Release notes beside the archive, with its name, are embedded in its item.
cp "$OUT/notes.md" "$OUT/sparkle/MacArch-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account macarch --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT/sparkle"
cp "$OUT/sparkle/appcast.xml" "$OUT/appcast.xml"

spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
echo "Built $OUT"

if [ -n "$PUBLISH" ]; then
    # The GitHub release's notes: MacArch's, then LinuxArch's.
    cp "$OUT/notes.md" "$OUT/release-notes.md"
    LINUX_DEBS=
    if [ "$LINUX" != "0" ]; then
        LINUX_DEBS=$(ls "$OUT"/linux/*.deb)
        printf '\n## LinuxArch\n\n' >> "$OUT/release-notes.md"
        cat "$OUT/linux/linuxarch-notes.md" >> "$OUT/release-notes.md"
    fi
    git tag "v$VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" --repo "$REPO" --title "MacArch $VERSION" --notes-file "$OUT/release-notes.md" \
        "$DMG" "$ZIP" "$OUT/appcast.xml" $LINUX_DEBS
    echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
fi
