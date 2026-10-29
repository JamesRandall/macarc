#!/usr/bin/env bash
# Builds a Debian/Ubuntu package of LinuxArch: .build/deb/linuxarch_VERSION_ARCH.deb.
#
#   scripts/make-linux-deb.sh VERSION      (or: make deb)
#   STAGE_ONLY=1 scripts/make-linux-deb.sh VERSION
#       just .build/deb/stage, with its DEBIAN/control, for dpkg-deb to build
#       elsewhere (scripts/release-linux.sh: under Rosetta, dpkg-deb's tar fails)
#
# The programs carry the Swift runtime, so the package depends only on the
# system's libraries (found by dpkg-shlibdeps).
set -euo pipefail

version="${1:?usage: $0 VERSION}"
root="$(cd "$(dirname "$0")/.." && pwd)"
arch="$(dpkg --print-architecture)"
stage="$root/.build/deb/stage"
package="$root/.build/deb/linuxarch_${version}_${arch}.deb"

cd "$root"
rm -rf "$stage"
make install PREFIX=/usr DESTDIR="$stage"

# The libraries the programs link, as package dependencies.
mkdir -p "$stage/debian"
cat > "$stage/debian/control" <<EOF
Source: linuxarch
EOF
programs=("$stage/usr/lib/linuxarch/linuxarch" "$stage/usr/lib/linuxarch/macarch-mcp" "$stage/usr/lib/linuxarch/macarch-cli")
depends="$(cd "$stage" && dpkg-shlibdeps -O "${programs[@]#"$stage"/}" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
rm -rf "$stage/debian"

size="$(du -sk "$stage/usr" | cut -f1)"
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<EOF
Package: linuxarch
Version: $version
Architecture: $arch
Maintainer: James Randall <james@accidentalfish.com>
Installed-Size: $size
Depends: $depends
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-ugly, gstreamer1.0-libav
Section: otherosfs
Priority: optional
Homepage: https://github.com/acorn-playground/macarch
Description: Acorn Archimedes emulator
 LinuxArch is MacArch for Linux: an emulator of the Acorn Archimedes 300
 and 400 series, the A540, the A3000, and the A5000, A3010, A3020 and
 A4000, running RISC OS 2 or 3 from a ROM you own, or ArcLibre. It has
 floppy and hard disc images, rewind, save states and screenshots, and a
 CLI and MCP server sharing the same emulation.
EOF

[ -n "${STAGE_ONLY:-}" ] && { echo "$stage"; exit 0; }
dpkg-deb --root-owner-group --build "$stage" "$package"
echo "$package"
