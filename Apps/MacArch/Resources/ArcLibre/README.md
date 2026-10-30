# ArcLibre

ArcLibre is a free ROM for the Acorn Archimedes, restored from Acorn's
publicly released RISC OS source (the cleaned RISC OS 3.60 cohort, under the
Apache License 2.0), with RISC OS 3.11 compatibility as its aim. MacArch
includes it so that it works without one of Acorn's ROMs. This is release
0.9.1 (30 Oct 2026), in its two forms.

- `arclibre-0.9.1-2mb.rom`: the 2 MB ROM, for any Archimedes. SHA-256
  `9e7aa465948c06802c24b46de00635214d6b410df9d788963bbfbf9ef07a4eb9`.
- `arclibre-0.9.1-2mb-extras.adf`: an 800K floppy with what the 2 MB ROM has
  no room for: DOSFS, !Alarm and !Printers, with !System and !Scrap. SHA-256
  `5a2ade9a02bc69246173ad657225ded9310c86a122295ab2a42eb3fbc8a6e7fa`.
- `arclibre-0.9.1-4mb.rom`: the 4 MB ROM, with DOSFS, Alarm and printing
  built in, for the A5000, A3010, A3020 and A4000 (the earlier machines'
  sockets take at most 2 MB). SHA-256
  `2ae82b6d9342f20f4c400a97b5615332fb2d449ead9571566376c33169f016d6`.
- `LICENSE-Apache-2.0`: the licence of the RISC OS sources and of
  ArcLibre's own code.
- `LICENSE-FPEmulator`: the floating point emulator's ARM Limited BSD
  notice and its Apache-2.0 terms.
- `LICENSE-Squash-BSD3`: the Squash compressor's BSD notice.
- `LICENSING.md`: where each component came from, with its exact upstream
  revision, and what was changed.

Source: https://github.com/acorn-playground/arclibre

To update it, build and package an ArcLibre release (its
`dist/arclibre-VERSION` folder), then run
`scripts/update-arclibre.sh VERSION PATH-TO-ARCLIBRE` from MacArch's root,
and put the new SHA-256s in `ROMImporter.known` and here.
