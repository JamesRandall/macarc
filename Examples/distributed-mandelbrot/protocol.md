# Distributed Mandelbrot: specification, version 1

A pre-canned demo for the Network Studio, after MacBeeb's. Several
Archimedes on one emulated Econet draw the Mandelbrot set between them.
One machine, the **coordinator**, hands out tiles of the picture; each
**worker** computes its tiles in its own ARM and sends the counts back;
the coordinator draws them as they arrive. Every pixel is computed by an
emulated machine and every message goes over the emulated Econet.

This file is the frozen contract. The guest programs (`*.s` beside it)
and the Swift side (the traffic decoder and the test oracle) must match
it byte for byte. Change it only with a new version.

## The network

A ready-made template, **Distributed Mandelbrot**:

- A **Level 4 file server** (station 254) on its own hard disc, built by
  MacArch from the user's Level 4 disc, with the demo's programs added to
  `$.LIBRARY` and the workers' boot file (below).
- A **coordinator** machine (the "Guide", an A5000 or A440) that runs
  `Mandel`.
- Several **worker** machines (A3000s), each configured to boot from the
  network.

The classroom idea: the technician set every machine to boot from the
server. At power-on a worker logs on and the server's boot file starts
the worker program. The teacher, at the coordinator, types `Mandel`. No
outside driver: the machines do it themselves, as the real classroom did.

### How a worker starts

A worker's CMOS is configured for network boot: file system NetFS (byte
5), boot at power-on (byte 16 bit 4), and the file server's station in
bytes 1-2. At power-on NetFS logs the station on as user **BOOT** (no
password: RISC OS's NetFS has `Logon Boot` built in, so the user can't be
another) and runs the boot file in BOOT's directory, as BOOT's boot
option (2, `*Run`) says. NetFS's boot file is `!ArmBoot`, not `!Boot`
(which, on a Level 4 disc, is the server's own `$.!Boot`). So the server's
disc has `$.BOOT.!ArmBoot`, an Obey file that does
`Run Net:$.LIBRARY.Worker`. The worker program then waits for a
coordinator over Econet. Nothing writes to the worker from outside.

Level 4's supplied Users file already has BOOT, with boot option 2 and
`BOOT` for its directory; it isn't changed. The demo's files are readable
by everyone (public read), or Level 4 refuses BOOT and GUEST "Insufficient
access". The coordinator is configured for NetFS without boot, and logs
on as GUEST.

## Ports

Application choices, not Acorn-assigned. Frames go with
`Econet_DoTransmit` (SWI &40009), control byte &80. Receivers open
`Econet_CreateReceive` blocks (SWI &40000) that accept any station and
check the sender.

| Port | Who listens | For |
| --- | --- | --- |
| &C0 | the coordinator (`Mandel`) | HELLO, READY, RESULT, STATUS |
| &C1 | a worker | WELCOME, ASSIGN, ACK, COMPLETE, DISCOVER, START, STOP |

## Header (14 bytes, little-endian)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | `"MA"` (&4D &41) |
| 2 | 1 | version = 1 |
| 3 | 1 | type |
| 4 | 4 | runId (the coordinator's start time; 0 before WELCOME) |
| 8 | 2 | messageId: the sender's counter, mod 65536 |
| 10 | 1 | sender station (diagnostic) |
| 11 | 1 | flags = 0 |
| 12 | 2 | payload length |

A receiver ignores a frame unless it's at least 14 bytes, the magic and
version are right, 14 + payload length equals the received length, and
the payload length is exactly what its type needs (RESULT: 11 + width ×
height).

## Messages

| Code | Name | Payload | Len |
| --- | --- | --- | --- |
| 1 | HELLO | role u8 (1 = worker), reserved u8, numeric formats u8 (bit 0 = 4.28), worker version u8 | 4 |
| 2 | WELCOME | width u16, height u16, maxIterations u16, tileWidth u8, tileHeight u8 | 8 |
| 3 | READY | station u8 | 1 |
| 4 | ASSIGN | tileId u16, epoch u16, x u16, y u16, width u8, height u8, startReal i32, startImag i32, stepReal i32, stepImag i32, maxIterations u8, reserved u8 (0) | 28 |
| 5 | RESULT | tileId u16, epoch u16, x u16, y u16, width u8, height u8, format u8 (1 = raw counts), then width × height counts, row-major from the top | 11 + w×h |
| 6 | ACK | tileId u16, epoch u16, status u8 (0 = accepted, also for a resend of the accepted epoch; 1 = duplicate; 2 = stale epoch or not assigned to you) | 5 |
| 8 | COMPLETE | tiles u16 | 2 |
| 11 | DISCOVER | nonce u32 | 4 |
| 13 | START | nonce u32, coordinator u8 | 5 |
| 16 | STOP | nonce u32 | 4 |
| 17 | STATUS | nonce u32, state u8 (2 = running, 3 = stopping), worker version u8, coordinator u8 (0 = none yet) | 7 |

DISCOVER, START and STOP (on &C1) find workers and give them a
coordinator: a worker answers DISCOVER with STATUS (to the sender),
takes the coordinator from START, and STOP returns it to its boot state,
waiting for a coordinator. The nonce is the coordinator's runId. The
coordinator never writes to a worker's memory, and never starts a program
on another machine; it only sends these messages, which the worker
chooses to obey.

## Image and arithmetic

- MODE 12: 640 × 256 in 16 colours. The top 16 rows are status text; the
  picture is the 240 rows below. 20 × 15 tiles of 32 × 16, so 300 tiles.
  Tile `id = row × 20 + column`; origin `x = column × 32`, `y = row × 16`.
- **Fixed point 4.28**, signed, in 32 bits, so the view can be zoomed.
  The default view is real −2.5 … +0.7, imag −1.2 … +1.2. ASSIGN carries
  the tile's top-left `startReal`, `startImag` and the per-pixel steps
  `stepReal`, `stepImag`; a worker walks the tile by repeated addition.
  Exactly: pixel (x, y) is (`left + x × stepReal`, `top + y × stepImag`),
  wrapping as 32-bit registers do, with `left` = −671088640 (−2.5), `top`
  = 322122547 (1.2), `stepReal` = 1342177 (3.2 / 640) and `stepImag` =
  −2684354 (−2.4 / 240), each truncated towards zero.
- **maxIterations** default 64.
- The escape count of `(cr, ci)`:

  ```
  x = 0, y = 0
  for n in 0 ..< max:
      ax = |x|, ay = |y|
      if ax >= 2.0 or ay >= 2.0: return n     # in 4.28
      x2 = trunc(ax * ax)                      # product >> 28, truncated
      y2 = trunc(ay * ay)
      if x2 + y2 > 4.0: return n
      xy = trunc(ax * ay), with the sign of x·y restored
      y = 2·xy + ci
      x = x2 - y2 + cr
      n += 1
  return max
  ```

  The reference in the tests computes the same, so a worker's tile can be
  compared byte for byte. n = 0 never escapes, so a count is 1 … max.
- **Colour** of a count `n`: 0 (black) if `n == max`, else `1 + (n − 1)
  mod 14`. The fourteen band colours cycle when the picture's done.

## Exchanges

- **Register:** a worker sends HELLO to its coordinator every 1s until
  WELCOME. The coordinator answers HELLO with WELCOME and registers the
  worker. A known worker that sends HELLO again has its tile, if any, put
  back in the queue.
- **Render:**
  - On WELCOME a worker takes the runId and sends READY. Unanswered
    READY is resent every 2s.
  - The coordinator answers READY with ASSIGN: the worker's tile in
    flight (same epoch), else the next pending tile (its epoch then goes
    up by 1; the first assignment is epoch 1), else nothing (idle).
  - The worker computes, draws the tile on its own screen, sends RESULT,
    and resends it every 2s until it gets an ACK for the same tile and
    epoch. Then it sends READY.
  - A worker's HELLO, READY or RESULT with another runId is answered with
    WELCOME, which the worker always obeys, giving up its current tile.
- **Timeouts** (the MOS monotonic clock): a tile in flight for more than
  20s goes back in the queue and its worker is marked unresponsive. A
  RESULT with an old epoch is answered ACK status 2 and isn't drawn.
- **Discovery:** at the start `Mandel` sends DISCOVER to stations 1–63
  (not itself), tried twice; a worker that answers STATUS with another
  coordinator (or none) is sent START, and then registers with HELLO.
- **Rejoin:** while drawing, the coordinator sends DISCOVER once a second
  to a worker it marked unresponsive (its tile timed out, a frame to it
  couldn't be delivered, or it's said nothing for 10s), and to the next station 1–63 that isn't working
  for it, so machines that boot late join in. A worker switched off and
  on again has rebooted into the worker program (network boot), so it
  answers that DISCOVER, is sent START, and registers afresh with HELLO.
- **Completion:** when all 300 tiles are accepted the coordinator sends
  COMPLETE to every worker it knows, and answers later READY/HELLO in
  that run with COMPLETE. A worker that gets COMPLETE sends HELLO every 3s
  so a new run can take it on. The coordinator keeps the picture, cycling
  the fourteen band colours at the vertical sync, until a key is pressed.
- **Adopt / stop:** a second `Mandel` sends DISCOVER; a running worker
  answers STATUS, is sent START, takes the new coordinator and registers.
  `Mandel Stop` sends DISCOVER, and STOP to each worker that answers; the
  worker answers STATUS 3 and returns to its boot state, waiting.

## The programs

In the server's `$.LIBRARY`, so any logged-on station can run them.

| Program | Where it runs | What it does |
| --- | --- | --- |
| `Worker` | RMA, MODE 12 | A Utility (&FFC), so RISC OS loads it into the RMA. Waits for a coordinator, registers with it, takes tiles, computes and draws them, sends the counts until acknowledged. Its screen shows its station, coordinator, state and tiles done. Started by the worker's network boot; Escape stops it. |
| `Mandel` | the coordinator, MODE 12 | An Absolute (&FF8) at &8000. Finds workers with DISCOVER/START, registers them, keeps the 300-tile queue with an epoch per assignment, reassigns a tile out more than 20s, rejects stale results, draws accepted tiles into screen memory. On completion, COMPLETE and colour cycling; a key ends it, with a summary. `Mandel Stop` stops the workers instead. |

`common.s` has the shared definitions, and `shared.s` the routines both
include (compute, draw, the palette, checking and sending messages), so
the two agree exactly. The worker is position independent and fits in
4K of RMA.

## Memory

- The worker claims a workspace from the RMA (`OS_Module` 6) and keeps
  R12 pointing at it; its receive block, transmit buffers, band table and
  parameters live there. It frees the block on Escape.
- MODE 12's screen is read from VDU variable 148. Tiles are drawn as
  32-bit words, eight 4-bit pixels each, straight into screen memory.

## Build and test

- The sources assemble with MacArch's assembler (`macarch-cli assemble`,
  or the MCP `assemble` tool for source-level debugging). The assembled
  bytes go into the demo's Swift (`MandelbrotGuestFiles.swift`), checked
  by a test that assembles the sources again and compares
  (`MACARCH_WRITE_MANDELBROT=1` writes it afresh).
- `MandelbrotNetwork.fileServerDisc(fromLevel4Disc:geometry:)` builds
  the server's disc: the Level 4 applications from the user's disc, plus
  `$.LIBRARY` with the programs, and `$.BOOT.!ArmBoot`.
- The traffic decoder (`MandelbrotProtocol.swift`) reads these messages
  on &C0/&C1 for the Traffic and Mandelbrot views. A Mandelbrot view
  follows a render from the trace: the picture from accepted tiles, tiles
  in flight outlined in their worker's colour, the workers and progress.
  It only watches.
- `MandelbrotNetworkTests` runs the demo end to end through RISC OS's own
  software: workers boot and register, `Mandel` renders, and the
  coordinator's screen is compared with the reference, pixel for pixel. A
  benchmark times 1 … N workers.
