# Distributed Mandelbrot

Several Archimedes on one emulated Econet draw the Mandelbrot set between
them, after MacBeeb's demo. A coordinator hands out 300 tiles; each worker
computes its tiles in its own ARM and sends the counts back; the
coordinator draws them as they arrive. Every pixel is computed by an
emulated machine, and every message goes over the emulated Econet through
RISC OS's own Econet module. [protocol.md](protocol.md) is the contract.

## Running it

1. File ▸ New Network… ▸ **Distributed Mandelbrot**: a Guide (an A5000 on
   station 1), four A3000 workers (stations 2-5), a file server on
   station 254 and a clock.
2. Select the File Server and Set Up Level 4… with your Level 4 disc
   (Release 3's "Level 4" disc, or Issue 2's "FileServer" disc). MacArch
   builds its hard disc with the demo's programs in `$.LIBRARY`.
3. The server and the workers start again. The workers wait for the
   server to come up (about 30 s), then boot from the network into
   `Worker` and wait for a coordinator. (Whenever the network opens, the
   workers wait for the server like this.)
4. On the Guide, press F12 and type `*I AM GUEST`, then `*Mandel`. Mandel
   finds the workers, and the picture builds up. A key ends it.

The studio's Mandelbrot view follows the render from the frames alone,
and Traffic reads each message. Try switching a worker off part way: its
tile goes to another after 20 s, and when it's switched on again it boots
back into `Worker` and Mandel finds it. `*Mandel Stop` sends the workers
back to waiting.

## The files

| File | What it is |
| --- | --- |
| `protocol.md` | The protocol, version 1 |
| `common.s` | The shared definitions |
| `shared.s` | The routines both programs include: compute, draw, the palette, checking and sending messages |
| `worker.s` | `Worker`, a Utility (&FFC) that runs in the RMA |
| `mandel.s` | `Mandel`, the coordinator, an Absolute (&FF8) at &8000 |

They assemble with MacArch's assembler (`macarch-cli assemble worker.s`,
or the MCP `assemble` tool). The bytes are embedded in
`Packages/ArchimedesCore/Sources/ArchimedesCore/Econet/MandelbrotGuestFiles.swift`;
after changing a source, regenerate it with

    cd Packages/ArchimedesCore
    MACARCH_WRITE_MANDELBROT=1 swift test --filter MandelbrotGuestTests/testBuiltFromTheSources

## Tests

In `Packages/ArchimedesCore/Tests/ArchimedesCoreTests`:

- `MandelbrotGuestTests`: the embedded bytes are the sources'; the
  worker's own compute routine, run on an ARM2, matches the reference.
- `MandelbrotProtocolTests`: the decoder and the observer.
- `MandelbrotNetworkTests` (needs `discimages/release3/Level 4.adf` and
  `roms/riscos3_11`): the whole demo through RISC OS's own software, the
  coordinator's screen compared with the reference pixel for pixel; a
  worker switched off and on again; `Mandel Stop`. A few minutes each.
- `MandelbrotBenchmark` (`MANDELBROT_BENCH=1`): render times for 1, 2, 4
  and 8 workers.
