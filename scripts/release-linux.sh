#!/bin/sh
# Builds LinuxArch's release packages in Docker, into OUT (default
# build/releases/linux):
#   linuxarch_VERSION_amd64.deb, linuxarch_VERSION_arm64.deb
#   linuxarch-notes.md    (this release's section of Apps/LinuxArch/WHATSNEW.md)
#
#   scripts/release-linux.sh [OUT]
#   LINUX_ARCHS=arm64 scripts/release-linux.sh    just one architecture
#
# VERSION is LinuxArchApp.version (scripts/release.sh checks it's MacArch's),
# and Apps/LinuxArch/WHATSNEW.md must have a "## VERSION" section.
# scripts/release.sh runs this too, and attaches the packages to MacArch's
# GitHub release.
#
# Each architecture builds in an Ubuntu 26.04 container
# (Apps/LinuxArch/docker/Dockerfile); on Apple silicon, amd64 runs under
# emulation (Rosetta), so it's slower. The container builds a copy, in
# build/linux-src, of the files git tracks plus ArcLibre and the Level 4 disc
# (which git ignores), so nothing else in the tree (ROMs, disc images) goes
# in. (It's copied here rather than in the container: Ubuntu's tar opens files
# with openat2, which Rosetta lacks.) Swift's build folder is kept in a Docker
# volume for each architecture, macarch-linux-build-ARCH, so later builds are
# quicker; `docker volume rm` them to start afresh. Each package is then
# installed in a plain Ubuntu 26.04 container to check its dependencies.
set -e
cd "$(dirname "$0")/.."

OUT=${1:-build/releases/linux}
ARCHS=${LINUX_ARCHS:-amd64 arm64}
IMAGE=macarch-linux-build

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Apps/LinuxArch/Sources/LinuxArchApp.swift)
[ -n "$VERSION" ] || { echo "release-linux: no version in LinuxArchApp.swift" >&2; exit 1; }

NOTES=$(awk -v v="$VERSION" '
    /^<!--/ { comment = 1 } comment { if (/-->/) comment = 0; next }
    /^## / { on = ($2 == v); next }
    on' Apps/LinuxArch/WHATSNEW.md | sed -e '/./,$!d')
[ -n "$NOTES" ] || { echo "release-linux: Apps/LinuxArch/WHATSNEW.md has no \"## $VERSION\" section" >&2; exit 1; }

docker info >/dev/null 2>&1 || { echo "release-linux: Docker isn't running" >&2; exit 1; }

EXTRAS="Apps/MacArch/Resources/ArcLibre/ArcLibre.rom Apps/MacArch/Resources/Level4.adf"
for extra in $EXTRAS; do
    [ -f "$extra" ] || { echo "release-linux: $extra is missing" >&2; exit 1; }
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
printf '%s\n' "$NOTES" > "$OUT/linuxarch-notes.md"

SRC=build/linux-src
rm -rf "$SRC"
mkdir -p "$SRC"
{ git ls-files -z; printf '%s\0' $EXTRAS; } | COPYFILE_DISABLE=1 tar -c --no-xattrs --null -T - -f - | tar -x -f - -C "$SRC"
SRC=$(cd "$SRC" && pwd)

NATIVE=$(docker version --format '{{.Server.Arch}}')
docker build --quiet --platform "linux/$NATIVE" -t "$IMAGE:$NATIVE" Apps/LinuxArch/docker >/dev/null

for arch in $ARCHS; do
    echo "Building LinuxArch $VERSION for $arch..."
    docker build --quiet --platform "linux/$arch" -t "$IMAGE:$arch" Apps/LinuxArch/docker >/dev/null
    rm -f "$OUT/linuxarch_${VERSION}_$arch.deb"
    docker run --rm --platform "linux/$arch" \
        -v "$SRC:/src" -v "macarch-linux-build-$arch:/src/.build" "$IMAGE:$arch" \
        sh -c "STAGE_ONLY=1 make deb"
    # dpkg-deb in a container native to this machine: under emulation, its tar
    # can't read the files (Rosetta lacks openat2).
    docker run --rm --platform "linux/$NATIVE" -v "macarch-linux-build-$arch:/build" -v "$OUT:/out" "$IMAGE:$NATIVE" \
        dpkg-deb --root-owner-group --build /build/deb/stage "/out/linuxarch_${VERSION}_$arch.deb"

    echo "Checking the $arch package installs..."
    docker run --rm --platform "linux/$arch" -v "$OUT:/out:ro" ubuntu:26.04 sh -c "
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /out/linuxarch_${VERSION}_$arch.deb >/dev/null &&
        ldd /usr/lib/linuxarch/linuxarch /usr/lib/linuxarch/macarch-mcp /usr/lib/linuxarch/macarch-cli | grep 'not found' && exit 1;
        macarch-cli rom-info /usr/share/linuxarch/ArcLibre/ArcLibre.rom | grep -q ArcLibre"
done

echo "Built LinuxArch $VERSION in $OUT"
