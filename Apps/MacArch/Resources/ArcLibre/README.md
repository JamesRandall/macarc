# ArcLibre

ArcLibre is a free ROM for the original ARM2 and ARM3 Archimedes, restored
from Acorn's publicly released RISC OS source (the cleaned RISC OS 3.60
cohort, under the Apache License 2.0), with RISC OS 3.11 compatibility as
its aim. MacArch includes it so that it works without one of Acorn's ROMs.
It has drivers for the machines before the A5000 (MacArch's tests start its
desktop on an A3000, an A440/1 and an A310 with an ARM3), not for the A5000
family.

- `ArcLibre.rom`: ArcLibre 0.8 (28 Oct 2026), 2 MB, SHA-256
  `d83d2e8cbb6adb1c37883e194c527279b5233c5ce3b0c9c324f6f6ae91447f2d`.
- `LICENSE-Apache-2.0`: the licence of the RISC OS sources and of
  ArcLibre's own code.
- `LICENSE-FPEmulator`: the floating point emulator's ARM Limited BSD
  notice and its Apache-2.0 terms.
- `LICENSE-Squash-BSD3`: the Squash compressor's BSD notice.
- `LICENSING.md`: where each component came from, with its exact upstream
  revision, and what was changed.

Source: https://github.com/acorn-playground/ArcLibre

To update it, build and package ArcLibre (`make arclibre-package`), then
run `scripts/update-arclibre.sh PATH-TO-ARCLIBRE` from MacArch's root, and
put the new SHA-256 in `ROMImporter.known` and here.
