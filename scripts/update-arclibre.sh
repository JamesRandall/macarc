#!/bin/sh
# Copies an ArcLibre release (its dist/arclibre-VERSION folder: the 2 MB
# and 4 MB ROMs and the 2 MB ROM's extras disc, checked against its
# SHA256SUMS) and its licences into the app's resources.
# Usage: scripts/update-arclibre.sh VERSION [PATH-TO-ARCLIBRE] (default ../arclibre)
set -e
VERSION=${1:?usage: scripts/update-arclibre.sh VERSION [PATH-TO-ARCLIBRE]}
SRC=${2:-../arclibre}
RELEASE=$SRC/dist/arclibre-$VERSION
DEST=Apps/MacArch/Resources/ArcLibre
FILES="arclibre-$VERSION-2mb.rom arclibre-$VERSION-4mb.rom arclibre-$VERSION-2mb-extras.adf"
(cd "$RELEASE" && grep -E " ($(echo $FILES | tr ' ' '|'))\$" SHA256SUMS | shasum -a 256 -c)
rm -f "$DEST"/*.rom "$DEST"/*.adf
for f in $FILES; do cp "$RELEASE/$f" "$DEST/"; done
cp "$SRC/licenses/Apache-2.0" "$DEST/LICENSE-Apache-2.0"
cp "$SRC/src/FPEmulator/LICENSE" "$DEST/LICENSE-FPEmulator"
cp "$SRC/licenses/Squash-BSD3" "$DEST/LICENSE-Squash-BSD3"
cp "$SRC/LICENSING.md" "$DEST/LICENSING.md"
(cd "$DEST" && shasum -a 256 *.rom *.adf)
echo "Add the ROMs' SHA-256s to ROMImporter.known and $DEST/README.md if they're new."
