# ArcLibre

ArcLibre is a free ROM for the Acorn Archimedes, restored from Acorn's
publicly released RISC OS source (the cleaned RISC OS 3.60 cohort, under the
Apache License 2.0), with RISC OS 3.11 compatibility as its aim. MacArch
includes it so that it works without one of Acorn's ROMs. This is release
0.9 (29 Oct 2026), in its two forms.

- `arclibre-0.9-2mb.rom`: the 2 MB ROM, for any Archimedes. SHA-256
  `ee1c8f489ba8d3cc7e6964eee6acae9df41413b3607d4f6943a22fb1951a944c`.
- `arclibre-0.9-2mb-extras.adf`: an 800K floppy with what the 2 MB ROM has
  no room for: DOSFS, !Alarm and !Printers. SHA-256
  `b2ddd57d9db294b46bd2ccedfc8aa98b2f918fb40fd7e74065859c9bb3a9a294`.
- `arclibre-0.9-4mb.rom`: the 4 MB ROM, with DOSFS, Alarm and printing
  built in, for the A5000, A3010, A3020 and A4000 (the earlier machines'
  sockets take at most 2 MB). SHA-256
  `d50d370b3254e1a159c26b19e893f2b1b6d440fee0a4b80669739e5449ca062e`.
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
