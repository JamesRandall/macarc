# MacArch in the browser (WebAssembly)

The real `ArchimedesCore` (the same Swift emulation the Mac app runs) compiled
to WebAssembly with the official Swift SDK, driven from a browser page. There is
no second emulator: JavaScript only supplies time, input, files and a screen.

```text
                 Packages/ArchimedesCore/Sources/ArchimedesCore
           ARM2/ARM3, MEMC, IOC, VIDC, floppy, snapshots, launcher
                                 |
                ArchimedesEmbedding (EmbeddedMachine)
       bytes and integers in, RGBA/audio/state out; no paths, clocks, threads
                 |                                   |
        native Swift (tests)              ArchimedesWasm: flat C-ABI exports
                                                     |
                               web/src/arc-wasm.js (buffer protocol, typed API)
                                                     |
                     web/src/arc-worker.js (Web Worker: pacing, OffscreenCanvas, audio)
                                                     |
                     web/src/main.js (page: controls, keyboard, pointer-locked mouse)
```

## Quick start

```sh
scripts/build-wasm.sh                       # -> web/public/archimedes.wasm
scripts/bundle-web.sh roms/arclibre.rom zarch \
    ~/code/macarc/top25/"Zarch (1987)(Superior Software).adf"   # -> web/public/bundled/ (local only)
node web/serve.mjs                           # http://localhost:8080/
```

Open the page, click **Play Zarch**: the machine (an A3000, 2 MB) switches on with
a CMOS reset, RISC OS boots to the desktop and the Classics launcher types the
game's start, exactly as the Mac app's Game Library does. Click the screen to
capture the mouse (left/middle/right are Select/Menu/Adjust); Esc releases it.

Without a bundle the page asks for a ROM file instead; **Insert disc…** takes any
floppy image the core reads (ADF/ADL/JFD/HFE). Files never leave the tab.

`web/public/` is gitignored: the module is a build product, and ROMs and
commercial discs must not be committed or published by default.

## Toolchain

| | Verified |
|---|---|
| Swift | swift.org 6.4.1-RELEASE toolchain (`~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain`) |
| SDK | `swift-6.4.1-RELEASE_wasm` (`swift sdk list`); override with `SWIFT`/`SWIFT_SDK` |
| Build | `swift build -c release --swift-sdk … --product ArchimedesWasm -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor -Xlinker --strip-all` |
| Node | 24.x (tests use `node:test`; Node ≥ 20) |
| Browser | Chrome 153 (headless, via `playwright-core` 1.64 and the system Chrome) |

The module is a **WASI reactor**: the host calls `_initialize` once, then the
exports. Its only imports are `wasi_snapshot_preview1` functions (35, mostly file
calls Foundation links but never makes); `web/src/wasi-shim.js` provides them
with no files, environment or arguments, so the same module loads in a browser,
a Worker, Node or workerd without any WASI library.

## Porting changes to the core

Small and host-neutral; native behaviour is unchanged (the full native suite passes):

- `Portable/Zlib.swift`: deflate/CRC through system zlib natively; a pure-Swift
  inflate and stored-block deflate where there's no zlib (WASI). Snapshots,
  zip and gzip media call it instead of zlib directly.
- `Portable/PortableSHA256.swift`: SHA-256 where there's no CryptoKit, so ROM and
  disc identities (and snapshot checks) match native exactly.
- `Portable/HostFiles.swift`: `open(2)` from whichever C library, and atomic
  writes only where the host has temporary files.
- `LockstepWorkers`: a single-threaded version where there's no Dispatch (the
  results are the same however many threads).
- The internet Econet rooms (URLSession, Keychain, WebSockets) are left out of
  WASI builds (`#if !os(WASI)` around those five files).
- One 64-bit literal in the debugger's expression evaluator (WASM's `Int` is 32 bits).

## ABI (version 1)

All in `Sources/ArchimedesWasm/Exports.swift`; `web/src/arc-wasm.js` wraps it.

- **Handles:** `arc_create(model, modelLen, ramKB, cmosReset, rom, romLen)` returns
  a positive handle; `arc_release(h)`. Unknown handles give error -1, never a trap.
- **Errors:** negative returns: -1 handle, -2 argument, -3 ROM, -4 configuration,
  -5 media, -6 snapshot. `arc_error_ptr/len` hold the UTF-8 message.
- **Input buffers:** `arc_alloc(n)` / `arc_free(p)`. The host fills a buffer,
  passes pointer and length, frees it after; the callee copies.
- **Output buffers:** one module-owned result buffer (`arc_result_ptr/len`), valid
  until the next call that produces output; the per-machine RGBA frame buffer is
  valid until the next `arc_frame_update` or `arc_release`.
- **Time:** `arc_run(h, ticks)` runs that many 24 MHz ticks (at most 10 guest
  seconds a call). Nothing advances between calls. `arc_ticks`, `arc_frame_count`, `arc_pc`.
- **Input:** `arc_key(h, code, down)` (Archimedes key matrix codes, 0x70–0x72 the
  mouse buttons), `arc_mouse_move(h, dx, dy)`, `arc_release_keys(h)`.
  `arc_follow_pointer(h, active, x, y, dx, dy)` follows the host's pointer
  instead of capturing it (the app's Follow the Mac pointer): RISC OS's
  pointer is steered to (x, y) in frame pixels, kept to the display area, and
  while it's off (dx, dy) goes as counts; `active` 0 stops. It returns 1 when
  the host can hide its own pointer there. Input
  takes effect at the current guest time, between runs.
- **Media:** `arc_insert_floppy(h, drive, p, n, wp)`, `arc_eject_floppy`,
  `arc_floppy_contents` (writes included; nothing is written back anywhere).
- **Classics:** `arc_start_classic(h, json, n, discs, n)` with the game's
  `classics.json` entry and its discs packed as `[u32 LE length, bytes]…`. The
  launcher is stepped every 0.25 *guest* seconds inside `arc_run`, so results
  don't depend on how the host slices time.
- **Video:** `arc_frame_update(h)` (1 if a new frame), then `arc_frame_ptr/width/height`
  (RGBA8, top row first, no padding) and `arc_frame_scale_x/y` (the monitor's
  pixel aspect: 416×288 at 2×2 for Zarch's mode). `arc_frame_checksum` is the
  CLI's FNV-1a `frameChecksum`.
- **Audio:** `arc_audio_rate(h, hz)`, then `arc_audio_take(h)` returns the number
  of interleaved stereo float32s at `arc_audio_ptr()`.
- **State:** `arc_save_state` / `arc_restore_state`: the app's own snapshot format
  (complete machine state). A restore finds its floppies among those given to
  that machine, by SHA-256.
- `arc_read_memory(h, address, length, logical)`, `arc_recent_text`, `arc_rom_version`.

## The browser host

- The worker owns the module and runs guest time in 1 ms multiples every 4 ms
  against `performance.now()`. Catch-up is capped at 100 ms, so a stalled or
  hidden tab never replays a backlog; the page pauses the machine while hidden.
- Frames are drawn by the worker into a transferred `OffscreenCanvas`; only
  changed frames are converted and drawn. The CSS aspect ratio follows the
  frame's size and pixel scaling.
- Sound goes from the worker straight to an AudioWorklet's port (a small ring
  buffer: silence when dry, oldest dropped past 250 ms).
- Keys map by position (`KeyboardEvent.code`) to the Archimedes keyboard;
  repeats are suppressed (RISC OS repeats for itself). Held keys and buttons are
  released on blur, on hiding, and when the pointer lock ends.
- Messages to the worker carry a machine generation; input for a machine that
  a power cycle replaced is dropped.

## Tests

```sh
cd Packages/ArchimedesCore && swift test --filter ArchimedesEmbeddingTests   # native
cd web && npm test                                                          # WASM in Node
cd web && npm install && node serve.mjs & node tests/browser-smoke.mjs      # Chrome, end to end
```

Native and WASM assert the same fixtures (`Packages/ArchimedesCore/Tests/Fixtures/wasm-parity.json`):

- **ROM-independent:** a small ROM assembled from source in the fixture (it jumps
  to high ROM and fills 64 KB of RAM with a recurrence) runs 50 × 480,000 ticks;
  final ticks, PC and a RAM SHA-256 must match. Plus snapshot save → fresh
  machine → continue identically, invalid inputs (bad model, ROM, disc, drive,
  key, run length, truncated snapshots, unknown handles) failing with error codes,
  independent simultaneous machines, and 20 create/run/snapshot/release cycles
  with no growth in linear memory.
- **With local licensed fixtures** (skipped without them; `MACARCH_TEST_ROM`,
  `MACARCH_TEST_ZARCH`): Zarch launched from a CMOS reset with arclibre.rom
  (RISC OS 3.60) gives the same frame numbers and frame checksums natively and
  in WASM at 10, 20, 30 and 40 guest seconds.
- **Browser smoke:** fresh load, start, boot → desktop → game start, ≥ 90 % real
  time, a key press into the game, pause holds guest time and resume continues
  it, release on blur, save/load state, reset, power cycle, and no page errors.

## Measurements

Apple M4 Max, macOS 27, release builds, Zarch from a CMOS reset with arclibre.rom:

| | |
|---|---|
| Native (`macarch-cli run --seconds 40`) | 37.9× real time (1.05 s wall) |
| WASM in Node 24 (same 40 s, launcher running) | 27.7× real time (1.44 s wall): ~73 % of native |
| Chrome 153, interactive | 100 % of real time, 50 frames/s; a 4 ms slice of guest time takes 0.40 ms median, 0.70 ms p95 |
| Module | 55.3 MB stripped; 19.6 MB gzip -9, 12.7 MB brotli -q 11 |
| Startup | instantiate ~35 ms (Node), create machine ~33 ms; page ready ~130 ms from localhost |
| Linear memory | ~50 MB with one machine running |
| Snapshot | ~3 MB under WASM (stored deflate blocks); natively zlib-compressed. Both formats read on either side |

## Limitations and next steps

- **Size.** Most of the module is ICU data and code from full `Foundation`
  (`FoundationInternationalization`). Moving the core to `FoundationEssentials`
  on WASI would remove it, but it touches ~200 call sites (`String(format:)`,
  `NSString` paths, `trimmingCharacters`, POSIX calls), so it was left for a
  separate change. Serve with brotli/gzip meanwhile.
- **Snapshots are uncompressed under WASM** (the fallback writes stored deflate
  blocks). They are still valid zlib streams, so native reads them.
- Hard discs (`HardDiscImage` is file-descriptor based), Econet and the
  debugger aren't exposed to the browser. Floppy writes stay in memory
  (`arc_floppy_contents` can export them; the page doesn't offer that yet).
- **Cloudflare isn't attempted here.** The module uses only the WASI calls the
  shim stubs, so it should instantiate in workerd. But at 19.6 MB gzipped it is over
  Workers' published compressed size limits (check the current figures). It
  needs the FoundationEssentials work first.
- The arclibre ROM needs a CMOS reset to start the desktop (it boots to a
  Supervisor prompt from blank CMOS), which the embedding does by default.
