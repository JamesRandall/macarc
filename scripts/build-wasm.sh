#!/bin/sh
# Builds ArchimedesWasm (the real ArchimedesCore, as a WASI reactor module)
# into web/public/archimedes.wasm.
#
# Needs the swift.org 6.4.1 toolchain and its matching WebAssembly SDK:
#   https://www.swift.org/documentation/articles/wasm-getting-started.html
# Override with SWIFT=/path/to/swift and SWIFT_SDK=<id from `swift sdk list`>.
set -eu
cd "$(dirname "$0")/.."

SWIFT=${SWIFT:-}
if [ -z "$SWIFT" ]; then
    for tc in "$HOME/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain" "/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain"; do
        if [ -x "$tc/usr/bin/swift" ]; then SWIFT="$tc/usr/bin/swift"; break; fi
    done
fi
SWIFT=${SWIFT:-swift}
SWIFT_SDK=${SWIFT_SDK:-swift-6.4.1-RELEASE_wasm}

if ! "$SWIFT" sdk list 2>/dev/null | grep -qx "$SWIFT_SDK"; then
    echo "error: Swift SDK '$SWIFT_SDK' isn't installed for $SWIFT." >&2
    echo "Installed: $("$SWIFT" sdk list 2>/dev/null | tr '\n' ' ')" >&2
    echo "See https://www.swift.org/documentation/articles/wasm-getting-started.html" >&2
    exit 1
fi
echo "Using $("$SWIFT" --version 2>&1 | head -1) with $SWIFT_SDK"

SCRATCH=${SCRATCH:-.build/wasm}
"$SWIFT" build --package-path Packages/ArchimedesCore --scratch-path "$SCRATCH" \
    -c release --swift-sdk "$SWIFT_SDK" --product ArchimedesWasm \
    -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor \
    -Xlinker --strip-all

mkdir -p web/public
cp "$SCRATCH/release/ArchimedesWasm.wasm" web/public/archimedes.wasm
ls -l web/public/archimedes.wasm
