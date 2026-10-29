#!/bin/sh
# Copies a packaged ArcLibre (its dist/arclibre.rom, checked against its
# .sha256) and its licences into the app's resources.
# Usage: scripts/update-arclibre.sh [PATH-TO-ARCLIBRE] (default ../riscos-oss)
set -e
SRC=${1:-../riscos-oss}
DEST=Apps/MacArch/Resources/ArcLibre
(cd "$SRC/dist" && shasum -a 256 -c arclibre.rom.sha256)
cp "$SRC/dist/arclibre.rom" "$DEST/ArcLibre.rom"
cp "$SRC/licenses/Apache-2.0" "$DEST/LICENSE-Apache-2.0"
cp "$SRC/src/FPEmulator/LICENSE" "$DEST/LICENSE-FPEmulator"
cp "$SRC/licenses/Squash-BSD3" "$DEST/LICENSE-Squash-BSD3"
cp "$SRC/LICENSING.md" "$DEST/LICENSING.md"
echo "ArcLibre ROM: $(shasum -a 256 "$DEST/ArcLibre.rom" | cut -d' ' -f1)"
echo "Add that SHA-256 to ROMImporter.known and $DEST/README.md if it's new."
