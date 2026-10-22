# Native Acorn Archimedes Emulator for macOS

**Implementation specification for Claude Code / Codex**  
**Working project name:** MacArch (provisional; do not let naming block implementation)  
**Primary stack:** Swift, SwiftUI, Metal, AVFoundation/Core Audio  
**Target:** Native macOS application, Apple Silicon first  
**Existing local inputs:** `references/` (emulator reference sources), `discimages/` (test game images)

---

## 0. Agent instructions — read this first

You are implementing a **genuinely native macOS Acorn Archimedes emulator**. The user has already built a BBC Micro emulator with Claude Code using reference emulators, and wants to repeat that approach here. Your role is to investigate the available source, make a clear plan, implement in small testable increments, and **use your own automated control interfaces to debug and test the emulator**.

**Start work immediately; do not ask routine setup or design questions.** Discover the repository as it actually exists, document material blockers, choose sensible defaults, and proceed. Never claim a game works merely because its disk image parses, or that a ROM boots merely because instructions execute.

**Non-negotiable constraints:**

1. Use **Swift for the emulator implementation**, not a C/C++ emulation library behind a SwiftUI shell. SwiftUI is the application UI; Metal is for presentation/scaling. System frameworks, standard Swift packages, and narrowly scoped platform APIs are fine.
2. The emulated machine must execute real **ARM2 machine code and genuine RISC OS ROMs**. No high-level reimplementation of games, simulated screenshots, hard-coded boot shortcuts, or game-specific magic addresses.
3. `references/` is **read-only reference material**, not production source. First inventory each project's licence and provenance. Implement original Swift code from specifications and independently confirmed behaviour. **Do not copy or mechanically translate code from GPLv2-only or otherwise incompatible sources into a GPLv3-only release.** Do not assume AI-generated code may be contributed upstream to any reference project.
4. `discimages/` is an **input/test corpus**. Preserve it bit-for-bit and do not check copyrighted images into a public repository. Use copy-on-write overlays for writes to disks.
5. Make a **headless emulator runner and a functioning MCP interface early**, rather than after the UI is finished. The agent must be able to operate the guest, inspect state, capture screenshots, set breakpoints, inject input and reproduce faults.
6. **Deterministic emulation is the default**. Guest time is based on emulated cycles/events; host wall-clock pacing is a presentation concern. Tests must not depend on UI frame timing.
7. The macOS app must work as a real everyday emulator, not only as a demonstration. Prefer accurate emulated hardware over short-term hacks that merely show a RISC OS desktop.
8. Work in small milestones. Keep the project compiling, run tests, record what actually works, and leave clear progress notes and known limitations.

### First actions

- Inspect the project root, `references/` and `discimages/`; enumerate reference implementations, licence files, available game images, image sizes/formats and any existing code.
- Look for a **user-supplied ROM** or configuration, but **do not download or bundle commercial ROMs automatically**. If none is available, build CPU/hardware unit tests and the app's ROM-import workflow first, then record the ROM as an integration-test blocker.
- Create `docs/reference-audit.md`, `docs/implementation-plan.md`, `docs/compatibility.md` and `docs/progress.md`.
- Identify an MIT/permissively licensed reference if one is present; use formal hardware documentation, tests and behavioural comparisons to clarify ambiguities. A reference's presence is not evidence that its source is legally reusable.
- Set up a native Xcode/SwiftPM project and ensure that **core tests run from the command line without the UI or a ROM**.
- Keep `references/` and `discimages/` unchanged.

---

## 1. Product vision and scope

Build a polished, native macOS emulator for **classic 26-bit ARM Acorn Archimedes computers**, with a carefully defined first machine and a credible path to others.

Initial machine profile:

| Component | Phase-one target |
| --- | --- |
| Machine | Acorn **A3000** |
| CPU | **ARM2**, nominal **8 MHz**, original **26-bit PC/status semantics** |
| RAM | **2 MiB** default; architecture must permit at least 1 MiB profiles |
| Core custom chips | **MEMC**, **VIDC**, **IOC** |
| Floppy controller | **WD1772-family** controller and A3000-compatible drive interface |
| Input | Archimedes keyboard and mouse protocol/interface |
| Firmware | User-provided **RISC OS 3.11** initially, with **RISC OS 2.x** compatibility as a high priority |
| Floppy | Unprotected **800 KB Archimedes ADFS D/E-sector images** as the first format |
| Display | Correct RISC OS desktop and dynamic game video modes, scaling/palette changes |
| Audio | Correct VIDC sound generation and DMA/buffering |
| Runtime | Native macOS windowed/full-screen app; standalone headless runner |

This is a **real hardware emulator**, not a RISC OS application compatibility layer.

### Why support RISC OS 2 as well as 3.11?

Some early games have genuine OS-version dependencies. A successful RISC OS 3.11 boot is not proof that a late-1980s game should run there. Make ROM profiles selectable, retain separate CMOS/configuration per profile, and verify reported game requirements before changing emulated hardware to compensate.

### Explicit non-goals for the first playable milestone

ARM3, ARM250, later A5000/A3010 machines, 82C711 controllers, expansion podules, SCSI/IDE drives, networking, printing, USB passthrough, debugger GUI, shader effects, full copy-protection image support and universal Archimedes game compatibility. The architecture should not prohibit these later.

---

## 2. Local inputs and discovery

### `references/`

Do not assume a fixed folder structure or specific emulator. Inventory actual contents. Likely useful upstream references, **only if present or independently consulted**, include:

- **Eichhörnchen** — A3000 implementation, MIT licence; particularly relevant for hardware decomposition and testing philosophy: <https://github.com/RichardBrown384/Eichhoernchen>
- **Arculator** — mature multi-machine compatibility reference, GPLv2; useful for observed behaviour, documentation and independent execution comparisons: <https://github.com/sarah-walker-pcem/arculator>
- **ArcEm** — additional independent Archimedes emulation lineage and hardware descriptions: <https://github.com/ArcEm-emu/ArcEm>

**Audit before use.** Some projects may be GPLv2-only, older ARMulator-derived, or subject to additional contribution restrictions. Write down the licences, copyright notices and any file-level exceptions. If the destination project's intended licence is undecided, keep the original Swift implementation clearly separated from the references, record provenance, and choose a compatible release licence before publication. Do not present this spec as legal clearance to redistribute code.

### `discimages/`

Discover files recursively. Expect a selection of:

- **Elite**
- **Lemmings**
- **Holed Out / Holed Out!!**
- **Repton 3**

Names and extensions are not guaranteed. Determine actual file formats from size, headers and metadata, not extensions alone. Create a **local-only test manifest** containing path, size, SHA-256, detected format, expected OS version if known, optional launch instructions and known result. Never alter originals to improve compatibility; create derivative working copies or overlays.

Not every image is a standard ADFS `.adf`. If images require FDI/HFE/SCP or preservation of nonstandard track data, record that as a **format-support requirement**, not as a game bug.

### ROM handling

- User imports legally obtained RISC OS ROM files through the app or a CLI argument.
- Recognise and validate relevant ROM layouts: e.g. appropriate combined ROM or the four-chip ROM sets commonly used with RISC OS 3.11, plus earlier OS ROM formats where supported.
- Document any required chip ordering, interleaving and checksum procedures; **verify them against real reference behaviour**.
- ROMs live under Application Support or explicit user-selected paths, not in the shipped app bundle or the public Git repository.
- First launch without a ROM must show a useful setup UI, not a blank/black screen.
- ROM selection is per-machine profile; do not share CMOS state across incompatible ROM profiles.

---

## 3. Engineering architecture

Separate deterministic guest emulation from the macOS UI. Use a Swift package for the core so headless tests, MCP and UI use the **same** emulator implementation.

Suggested layout; adapt intelligently to any code already in the project:

```text
./
├── references/                     # existing: read only
├── discimages/                     # existing: read only; exclude from public VCS
├── MacArch.xcodeproj               # or a documented equivalent Xcode setup
├── Packages/
│   └── ArchimedesCore/
│       ├── Package.swift
│       ├── Sources/ArchimedesCore/
│       │   ├── CPU/                # ARM2, 26-bit status, instructions, exceptions
│       │   ├── Bus/                # address decode, memory reads/writes, timing
│       │   ├── Memory/             # RAM, ROM, MEMC mapping, DMA
│       │   ├── Devices/            # IOC, VIDC, FDC, RTC/CMOS, input protocol
│       │   ├── Media/              # image readers, track/sector model, overlays
│       │   ├── Machine/            # composition, clock/events, snapshots
│       │   └── Diagnostics/        # traces, disassembler, counters
│       └── Tests/ArchimedesCoreTests/
├── Apps/
│   └── MacArch/                    # SwiftUI macOS target
│       ├── UI/
│       ├── Rendering/             # Metal presentation
│       ├── Audio/
│       └── Services/
├── Tools/
│   ├── macarch-cli/                # headless runner
│   └── macarch-mcp/                # MCP stdio server
├── docs/
├── tests/
│   ├── fixtures/                   # own or redistributable test fixtures only
│   ├── scripts/
│   └── reports/
└── README.md
```

**Architectural boundaries**

- **`ArchimedesCore`** must not import SwiftUI, AppKit or Metal. It must support `reset`, `stepInstruction`, `runCycles`, `runUntil`, media changes, control input, serialisation and diagnostics without a window.
- Guest CPU/device state belongs to one deterministic emulator executor. Frontend and MCP calls must be serialised through this executor; don't allow simultaneous memory mutation from the UI and MCP.
- A versioned **`MachineConfiguration`** specifies CPU variant, memory, ROM, monitor, floppy controller and future optional devices.
- Use explicit, documented `UInt8/UInt16/UInt32/UInt64` semantics. Audit wrapping arithmetic, signed overflow, endianness, unaligned accesses and bit shifts; Swift's default overflow traps are not guest behaviour.
- The emulation scheduler counts **guest cycles/events**, not sleeps or `Timer` callbacks. The display, audio and UI consume guest output.
- Instrumentation can be enabled without redefining guest behaviour. Any debug injection must be clearly an external test operation and must be disabled in ordinary runs.

---

## 4. CPU: ARM2 and 26-bit modes

This is a major correctness gate. The ARM2 is **not** a modern ARMv7/AArch64 CPU. Implement the **original ARM2 instruction set and architectural state**, not a generic contemporary ARM decoder.

Minimum functionality:

- 16 visible registers with correct **mode-dependent banked registers** and original PC/status arrangement.
- **26-bit addressing and PC/status representation**: condition flags, interrupt mask bits and mode bits interact with R15. Do not treat R15 as an ordinary 32-bit general-purpose register or assume an ARMv4 CPSR/SPSR model.
- All ARM2 condition codes and instruction classes: data processing, shifts (including register-specified shift rules), multiply, loads/stores, block transfers, branches/link, software interrupts, status/PC writes and other documented ARM2 operations.
- Accurate `PC` read semantics with instruction pipelining, especially for instructions that observe or write R15.
- Correct alignment, byte/word access semantics, sign/rotate behaviour where appropriate to ARM2, carry/overflow and edge cases.
- Exceptions, reset vector, supervisor/user/IRQ/FIQ modes, banked state, SWI, undefined instruction, aborts and IRQ/FIQ priority/masking.
- Predictable instruction and memory cycle accounting sufficient for boot, peripherals and games; optimise only after establishing correctness.
- A disassembler and structured instruction trace to support debugging.

Do not silently substitute an existing ARM library unless it can prove authentic ARM2/26-bit behaviour and still meets the Swift-only implementation requirement.

**CPU test requirement:** exhaustive or generated representative tests for all instruction families, every condition code, PC-related corner cases, flag arithmetic boundaries, register banking and exception entry/return. Cross-check with published architecture documentation and independently implemented reference tests where available. Include tests that intentionally distinguish ARM2 from later CPUs.

---

## 5. Bus, MEMC, interrupts and timing

### Memory / MEMC

Implement actual guest address decoding and the relevant MEMC behaviour:

- Physical RAM and ROM; memory access permissions and logical-to-physical page mapping as used by the target machine/OS.
- Supervisor versus user access rules; RAM/video/cursor/sound DMA address handling.
- Page map configuration and changes at runtime.
- Memory faults and access behaviour verified against references, not guessed.
- Timing/contention model sufficient for the guest's programmed display and DMA. Begin with a simple cycle/event model, then increase fidelity using tests.

### IOC

- Interrupt sources, masks, status/acknowledgement, FIQ/IRQ routing.
- Programmable timers and scheduled events; correct transitions visible to ARM2.
- Relevant keyboard, mouse, CMOS/RTC and floppy interface registers, as required for RISC OS startup.

### Keyboard/mouse

Implement the machine's **actual keyboard controller/serial protocol (KART/interface as appropriate)**. Mapping macOS key-down/up directly into a fake RISC OS keyboard buffer is not sufficient. Support mouse movement and all mouse buttons used by the desktop. Handle host key repeat separately from guest semantics. Ensure the mouse can be used comfortably in a normal macOS window (capture/release or absolute-relative translation as appropriate).

### Determinism

With the same ROM hash, machine configuration, CMOS state, disk hashes/overlays and scripted inputs, runs for a fixed number of guest cycles must produce the same CPU/device state and screen checksum. Seed or virtualise the RTC during automated tests.

---

## 6. VIDC, display and audio

### Video

Emulate **VIDC registers and video timing** rather than guessing a frame buffer layout. RISC OS and games change display modes, palettes and video registers directly.

Support:

- The target machine's standard pixel depths/modes, programmable timing, borders and video memory fetch.
- Palette updates **during a frame**, including scanline-sensitive changes where software relies on them.
- Hardware cursor behaviour, correct pixel order, scanline and frame boundaries.
- Native aspect ratio with optional 4:3, integer scale, nearest-neighbour/linear filtering and full-screen modes; never bake scaling into guest output.
- Render into an explicit frame/scanline output buffer owned by the core; use **Metal only to display and scale it**. A CPU renderer is fine initially if it is accurate enough to test. Later optimisations must preserve observable behaviour.
- Frame sequence counters, width/height/refresh metadata and stable frame hashes for tests.

### Audio

Implement the relevant VIDC sound registers, channel/sample behaviour and DMA/timing. Connect the output to **AVAudioEngine / Core Audio** using a bounded buffer and host sample-rate conversion where needed. The emulation must continue to work with audio muted, and audio must not control guest clock speed.

Audio is a game acceptance gate, not a permanent TODO. Provide a WAV-capture or sample-hash facility for tests where reasonable.

---

## 7. Floppy disk subsystem and media integrity

The games are a first-class compatibility suite. Implement a real **WD1772-family command/status/timing model** with the drive signals relevant to the A3000: selected drive/side, motor, index, seek, track, sector, data and relevant interrupts/DRQ handling. The OS must access disks through the guest's emulated controller.

### First format

- Unprotected **800 KB ADFS D/E raw-sector floppy images**. The usual Archimedes 800 KB layout is double-sided, 80 tracks per side, 5 × 1024-byte sectors per track, with appropriate sector ordering/skew as required by the controller and image representation.
- Parse sector geometry, preserve data exactly and model guest-visible sector IDs independently of host file byte offsets.
- Read/write/seek tests; validate known ADFS structures only as an independent convenience, **never to bypass guest floppy operations**.
- Automatic **read-only base image + copy-on-write overlay** for game disks. Clear UI indicator if a disk is modified. Exporting/committing a modified image must require an explicit user action.
- Disk insert/eject, motor status, disk change and optional multiple drive abstractions (drive 0 is mandatory initially).

### Later formats, conditionally required

FDI, HFE, SCP or other protected/flux-based formats, if one of the provided games actually needs them. Do not fake a missing protected sector response or patch the game's bytes. Report the exact unsupported command/track/format and add the appropriate support in a later phase. Some preservation formats store data that cannot be represented by a simple 800 KB `.adf`.

### Diagnostics

Trace floppy commands with time, side/track/sector, DRQ/IRQ transitions, data length, guest PC and outcome. Provide a `disk_inspect` command independently of booting the OS to list format, geometry, integrity checks and, when recognisable, ADFS files.

---

## 8. Native macOS experience

Build the interface as a conventional, polished **SwiftUI macOS application** with AppKit bridging only where justified (e.g. precise key event capture, low-level mouse input or Metal hosting).

### Essential UI

- Emulator display in a responsive, resizable window; authentic aspect ratio, nearest-neighbour scaling, full-screen and optional integer scaling.
- First-launch wizard to import a ROM and create a machine profile, with actionable error messages.
- `File > Insert Floppy…`, eject/swap floppy, drag-and-drop disk image, and recent images. Show label/filename and read-only/overlay state.
- `Machine > Power On / Reset / Pause / Resume` and clear current profile information (A3000, ARM2, RAM, ROM version).
- Keyboard input, mouse move and buttons, sensible modifier translation and configurable shortcuts that do not trap the user in guest input.
- View choices: aspect ratio, scaling filter, border behaviour, fullscreen, audio volume/mute, speed limiter and frame performance display.
- Persist safe preferences, ROM locations/bookmarks and non-ROM configuration in Application Support/UserDefaults. Handle macOS sandboxing/bookmarks if the final distribution strategy requires them.
- Clear, user-readable errors and a log export when a ROM or disk cannot be opened.

### Nice to have after functional milestones

- Quick save/load emulator state, keyboard mapping editor, game library thumbnails, screenshots and video recording, optional Sparkle updates after distribution/signing decisions.
- Keep the app structure suitable for later MacBeeb-like features, but do not sacrifice emulation correctness to implement polish early.

No Electron, SDL window, Qt UI or browser runtime in the shipping application.

---

## 9. Headless runner, diagnostic CLI and MCP server

**Make this early. This is a central part of the implementation strategy, not an optional integration.** The MCP server should expose the same `ArchimedesCore` engine used by the GUI and work in an ordinary local Claude Code or Codex session.

Preferred design:

- `macarch-cli`: execute ROM + disk deterministically for a specified number of guest cycles/instructions/frames; emit structured state and artifacts; return meaningful exit codes.
- `macarch-mcp`: proper **Model Context Protocol** server over **stdio** using a maintained Swift MCP implementation or a standards-compliant in-project implementation. Use JSON-RPC/MCP schemas correctly; **do not confuse a custom HTTP/JSON API with MCP**.
- Session lifecycle must prevent two clients executing/mutating one machine concurrently. Long runs should support cancellation and a bounded execution budget.
- For IDE use, an MCP server can own a headless machine; optional attach-to-running-GUI may come later via a separate, authenticated local IPC channel. Do not expose unauthenticated network control.

### Minimum MCP tools

| Tool | Behaviour |
| --- | --- |
| `machine_create` | Create/reset a session with an explicit machine profile and user-supplied ROM paths |
| `machine_status` | Running/paused state, guest cycles, PC, mode, current display, ROM/disk hashes, error summary |
| `machine_run` | Run bounded guest cycles, instructions or frames; optional stop conditions |
| `machine_step` | Step one or N instructions; report disassembly and relevant changes |
| `machine_reset` | Reset/power cycle without changing media |
| `cpu_registers` | Registers, banked registers when requested, flags, current mode, interrupt masks |
| `memory_read` | Read bounded guest memory in bytes/words with physical vs mapped semantics explicit |
| `memory_write` | Explicit debugger-only mutation, with validation and event logging |
| `breakpoint_set` / `breakpoint_clear` | PC breakpoints; memory watchpoints as practical |
| `trace_control` / `trace_read` | Enable filtered ring-buffer traces for CPU, bus, MEMC, IOC, VIDC, FDC; no unlimited logs |
| `floppy_insert` / `floppy_eject` | Mount/eject media with copy-on-write semantics |
| `disk_inspect` | Detect media format, geometry and optional ADFS catalogue metadata |
| `keyboard_event` / `keyboard_type` | Inject guest keyboard events/sequence with explicit guest cycle scheduling |
| `mouse_move` / `mouse_button` | Inject mouse movement/buttons reproducibly |
| `screen_capture` | Save actual emulated framebuffer as PNG and report dimensions, frame count, checksum, path |
| `machine_snapshot_save` / `machine_snapshot_load` | Versioned state capture/load; if postponed, explicitly gate commands until safe |
| `diagnostics_summary` | Recent interrupts, device commands, performance, guest exception counts and last fault |

### MCP tool safety and usability

- Paths should be scoped to explicitly authorised local test/ROM/media/output directories. Avoid arbitrary filesystem write or hidden network listeners.
- Bound all memory reads, traces, run durations and artifact sizes. Validate arguments and return machine-readable errors.
- Prefer returning concise JSON status, file paths and checksums over embedding huge raw traces in the chat.
- Support repeatable **test scripts** such as “boot with ROM X, run 20 million cycles, press F12, enter command, record frame hash”. Ensure schedules reference guest cycles, not host time.
- MCP startup and discovery instructions must be documented in `README.md`, including an example configuration usable by Claude Code and Codex; consult current MCP client documentation rather than inventing a client-specific setting.

### Debugging instrumentation

Every low-level failure should be diagnosable with tools that report **guest PC, instruction, mode, mapped/physical address, device command, interrupt and guest cycle**. Add optional trace comparison with reference emulators, normalising differences (e.g. PC pipeline display conventions). Tests must not rely exclusively on visual screenshots.

---

## 10. Game compatibility and acceptance suite

Treat the images in `discimages/` as **integration fixtures**, not redistributable source. Create a local manifest with the exact discovered names/hashes and document manual input sequences. Build deterministic automation wherever possible.

| Game | What it should exercise | Meaningful acceptance |
| --- | --- | --- |
| **Repton 3** | Early RISC OS/Arthur-era expectations, floppy I/O, palette/sprites, keyboard | Correct boot/launch for an appropriate ROM profile; playable level, working movement and no corruption |
| **Holed Out!!** | Input, frame presentation, graphics, disk activity | Launches, displays a course, registers shot/controls, progresses without hangs |
| **Elite** | ARM instruction/OS compatibility, game video, keyboard, timing, continuous simulation | Reaches main playable game, accepts control, redraws correctly, loads/transitions scenes without crashing |
| **Lemmings** | Video palettes/modes, sprite timing, mouse input, audio and continuous frame pacing | Gameplay level loads; cursor, lemmings, controls and sound behave correctly for an extended play session |

These are **targets to establish empirically**; do not assume every supplied image is compatible with RISC OS 3.11 or is unprotected. Try sensible, documented machine/ROM configurations before labeling an image broken. Keep a compatibility matrix covering:

```text
Title | image SHA-256 | format | ROM version | machine profile |
boots | launches | input | video | sound | stable 10-minute play | notes
```

### Quality bars

- **Machine boots:** a user-provided RISC OS ROM reaches a stable desktop with keyboard and mouse working; reset/second boot is reliable.
- **Disk works:** guest can mount an ADFS image, browse its directory, launch a program through guest OS calls, and read data correctly from the disk.
- **Game launches:** reaches actual game UI under correct machine settings, not just loading screen or title screen.
- **Game playable:** interactive and visually stable for at least 10 minutes, with no hangs, memory corruption, broken input or sustained audio stutter.
- **Reference comparison:** when possible, capture equivalent screenshots/guest traces from a mature emulator at the same game point and document known differences; no claim of pixel identity until tested.

### Regression harness

Create at least:

- Instruction test corpus (fast, no ROM).
- MEMC/page mapping and supervisor privilege tests (no ROM).
- IOC interrupts/timers and VIDC register-to-frame tests (no ROM).
- WD1772 command/status/DRQ/IRQ/read/write tests using **created, redistributable synthetic disk fixtures**.
- ROM boot smoke test (skipped with a clear reason if user ROM is absent).
- One scripted smoke per available game (skipped if file/format/ROM missing), saving screenshot + frame hash + concise event log.
- At least one repeatability test proving identical output across two runs from the same clean initial state.

Fail loudly on unsupported instructions/formats instead of silently returning zeros or inventing device behaviour.

---

## 11. Implementation phases and gates

### Phase 0 — Audit and scaffold

**Deliver:** reference licences/provenance inventory; game image manifest; documented source architecture; Swift package/Xcode project; CI-capable unit tests; minimal app shell; headless runner and MCP scaffold with actual tool discovery.

**Gate:** builds on macOS; `swift test`/Xcode tests pass; CLI and MCP can create a machine, inspect/reset it and report missing ROM without crashing.

### Phase 1 — ARM2 CPU correctness

Implement ARM2 interpreter, 26-bit PC/status, modes, exceptions, memory bus interface, disassembler, tracing, CPU tests.

**Gate:** generated ARM2 instruction test suite passes; headless CLI can load and execute controlled test programs, inspect state via MCP, and deterministically reproduce results.

### Phase 2 — Minimum complete motherboard

Implement RAM/ROM and MEMC, IOC registers/interrupts/timers, CMOS/RTC minimal required behaviour, keyboard controller interface, initial VIDC/scanline output and machine event scheduler.

**Gate:** a genuine supported RISC OS ROM makes measurable boot progress with traceable device access. Track and fix boot blockers. Avoid declaring victory on an empty video frame.

### Phase 3 — ROM boot and usable desktop

Complete necessary MEMC/IOC/VIDC behaviour, keyboard and mouse. Add ROM profiles, first-boot CMOS initialisation and a correct windowed Metal display.

**Gate:** RISC OS 3.11 boots reproducibly to a usable desktop with stable video, mouse and keyboard, survives soft reset; report exact ROM used. Add RISC OS 2 profile/boot support as next compatibility priority.

### Phase 4 — Floppy and first game

Implement WD1772 and first raw ADFS image format, disk overlays, media UI, disk inspection and automated disk tests. Choose **the simplest compatible image actually found** as the first game target (Repton 3 or Holed Out may be candidates; do not assume without inspection).

**Gate:** desktop can see guest floppy, inspect directory and launch at least one real game; guest floppy commands observable through MCP; original disk image SHA-256 unchanged.

### Phase 5 — All four games and sound

Add video/sound/keyboard/floppy timing fidelity, input improvements, missing OS profile support and extra image formats **only when the corpus demonstrates their need**. Prioritise correctness fixes found by actual game execution, not arbitrary feature expansion.

**Gate:** evaluate Repton 3, Holed Out, Elite and Lemmings against the playable criteria. Log all passes/failures with ROM, media hash, build and reproduction steps. Support 10-minute continuous game testing.

### Phase 6 — Native product polish

Finish robust SwiftUI app, import/recents, preferences, fullscreen, errors, performance tuning, packaging, debugging affordances, documentation and optional screenshots/video/state/Sparkle.

**Gate:** clean machine setup, boot, disk insert, game launch, pause/reset, quit/relaunch and disk integrity all work without developer intervention.

**Do not start Phase 6 polish if Phase 3/4 hardware correctness is still fragile.** Some phases can overlap where they reduce test/debug costs.

---

## 12. Performance and engineering standards

- Target an accurate nominal ARM2 8 MHz profile on contemporary Apple Silicon without sustained dropped frames or audio gaps. **Measure**, don't pre-optimise on guesses.
- Start with an interpreter. A JIT, dynamic recompilation or an ARM translation backend is **not** required, and would substantially raise complexity for little likely benefit at this target speed.
- Guest cycles drive behaviour; host pacing throttles to normal speed, with optional unthrottled mode for headless tests.
- Avoid per-instruction heap allocations and excessive ARC churn in hot paths; profile with Instruments only after correctness is established.
- Maintain strict separation of production code, local ROMs/game images and reference projects.
- Use XCTest/Swift Testing as appropriate; all newly fixed bugs should have a regression test at the narrowest possible level.
- Maintain readable Swift modules and a clear trace of reasoning for any undocumented hardware quirk. Do not hard-code special cases for these four games unless later verified as genuine hardware behaviour.
- Avoid 'success' screenshots generated outside the emulator; all captures must be the real guest framebuffer.
- Include clear failure modes for missing ROM, invalid media, unsupported opcodes/format and bad snapshots.

---

## 13. Deliverables

By the end of the project, provide:

1. Native macOS application with **SwiftUI UI and original Swift emulation core**.
2. Clean command-line build/test instructions and an executable headless runner.
3. Working **MCP server** with documented Claude Code/Codex configuration and tested end-to-end interaction.
4. Real ROM boot to RISC OS desktop and floppy/media handling, including safe copy-on-write overlays.
5. A game compatibility report and reproducible test recipes for **Elite, Lemmings, Holed Out and Repton 3**.
6. Meaningful CPU, hardware, disk and integration test coverage, with deterministic screenshots/traces.
7. Documentation of hardware support, licensing/provenance decisions, ROM ownership/import, known gaps and a prioritised roadmap.

### Required progress-update format for the coding agent

At the end of each milestone, update `docs/progress.md` with:

```markdown
## Phase N — [name]
- Implemented:
- Tests run and exact results:
- ROM version / image hashes used (if relevant):
- What is visibly working:
- What is definitely not working:
- Known bugs with reproduction steps:
- Next smallest correctness milestone:
```

No claim of completion without executable evidence, especially for the four games.

---

## 14. Suggested first coding-agent prompt

> Read `Acorn_Archimedes_Native_macOS_Emulator_Spec.md` in full. First audit `references/` (including licences) and `discimages/` (formats and hashes), inspect the existing project, and report the actual findings in `docs/reference-audit.md`. Then implement Phase 0 and begin Phase 1. Use Swift for the emulator, SwiftUI for the native app, and build a usable headless runner/MCP interface at the outset. Treat ROM and commercial game images as local, user-supplied fixtures. Keep the project compiling and tested, and update `docs/progress.md` as you go. Don't stop after writing a plan: implement and verify code, unless genuinely blocked by an external input.

---

## Technical reference links

- Acorn A3000 Technical Reference Manual (hardware overview): <https://manualzilla.com/doc/6003113/acorn-a3000-technical-reference-manual>
- Eichhörnchen reference project (MIT): <https://github.com/RichardBrown384/Eichhoernchen>
- Arculator reference project (GPLv2 and upstream AI contribution restriction): <https://github.com/sarah-walker-pcem/arculator>
- Arculator compatibility documentation (useful cross-check, not proof of identical image behaviour): <https://github.com/sarah-walker-pcem/arculator/blob/master/readme.txt>
- ArcEm reference project: <https://github.com/ArcEm-emu/ArcEm>

**Source note:** Links describe upstream projects and machine documentation. Local `references/` contents, exact disk formats, available ROMs and compatibility results must be verified by the coding agent inside this repository; they were not supplied with this specification.
