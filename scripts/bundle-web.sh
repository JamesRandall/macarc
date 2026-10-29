#!/bin/sh
# Bundles a ROM and a Classic's discs with the web page, for local use:
# they're copied into web/public/bundled/ (gitignored, never committed) with
# a manifest the page reads at startup.
#
#   scripts/bundle-web.sh <rom> <game id> <disc>...
#   scripts/bundle-web.sh roms/arclibre.rom zarch "~/code/macarc/top25/Zarch (1987)(Superior Software).adf"
#
# ROMs and commercial discs are generally not yours to redistribute: keep
# the bundle on your own machine unless you know you may share them.
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 3 ] || { echo "usage: $0 <rom> <game id> <disc>..." >&2; exit 1; }
rom=$1; game=$2; shift 2

out=web/public/bundled
rm -rf "$out"
mkdir -p "$out"
cp "$rom" "$out/rom.bin"
cp Apps/MacArch/Resources/Classics/classics.json "$out/classics.json"
discs=""
i=0
for d in "$@"; do
    i=$((i + 1))
    cp "$d" "$out/disc$i.img"
    discs="$discs${discs:+, }\"disc$i.img\""
done
cat > "$out/manifest.json" <<JSON
{
  "rom": "rom.bin",
  "classic": { "id": "$game", "catalogue": "classics.json", "discs": [$discs] }
}
JSON
ls -l "$out"
