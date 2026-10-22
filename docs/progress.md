# Progress

## Phases 0–3: scaffold, ARM2, motherboard, ROM boot (2026-10-20)
- Implemented: ARM2 core and disassembler; MEMC (CAM, PPL, ROM overlay, DMA pointers); IOC (IRQ/FIQ, 4 timers, KART, I2C control, banks 1 and 5); PCF8583 CMOS/RTC on guest time; keyboard and mouse protocol; VIDC (timing, palette incl. 8 bpp, cursor, line DMA, sound DMA); WD1772 (types I–IV, DRQ/INTRQ via FIQ) with drive latches; ADF detection and copy-on-write; ADFS inspector; headless CLI; MCP stdio server (24 tools); SwiftUI/Metal app with audio, mouse capture, floppy menu and drag and drop.
- Tests: `cd Packages/ArchimedesCore && swift test` → 47 tests, 0 failures (37 CPU, 4 MEMC, 2 IOC, 3 floppy, 1 ROM boot smoke test that is skipped without a ROM).
- ROMs: RISC OS 3.11 (`e916a0b8…`), RISC OS 2.00 (`b2658bb1…`).
- Visibly working: 3.11 desktop at about 20 s guest time on a CMOS-reset first boot (about 12 s with saved CMOS). Pointer and clicks work. Inserting Repton 3 and clicking `:0` opens the Filer window listing the disc. 2.00 also reaches its desktop. Runs about 55× real time when unthrottled; the app runs at real time.
- Bugs found and fixed via traces: (1) unaligned word stores have to reach MEMC unmasked, because the CAM decodes A0/A1 (POST failure bit &400). (2) Duplicate CAM mappings now resolve to the most recent write (POST protection test, &800). (3) IOC access cost reduced to 1–2 N cycles; at 1 µs it made boot about 2× slower.
- Definitely not working / untested: no game has been launched yet; sound has not been checked by ear; JFD images; snapshots (the tools return an error); Elite image missing.
- Known issues: the "Initialising…" splash lasts several seconds, so real-hardware boot timing still needs checking. The `#` key mapping is best-effort.
- Next smallest milestone: launch !REPTON3 from the Filer and record the result.

## Phase 4–5 start: first game (2026-10-20)
- Implemented: ARM2 three-stage prefetch pipeline. The words at A+4 and A+8 are latched before A executes and refilled after any PC change. Regression tests: `testStoreToNextInstructionDoesNotTakeEffect`, `testStoreTwoInstructionsAheadAlsoNotSeen`.
- Found via trace: Elite's loader at &3FE90 rewrites the BL at &3FE9C (the next instruction) and relies on the old copy executing. Without prefetch it branched into zeroed memory ("abort on instruction fetch at &00080004").
- Tests: 49 run, 0 failures.
- Visibly working: Elite (Acorn User Aug 95 disc, sha256 b6853ba6…) loads from an ADFS E disc, shows the 3D title screen, and reaches the Commander status screen after Space. ADFS E-format directories also browse correctly.
- Not yet checked: flight, sound, and 10-minute stability.

## Phase 5: sound (2026-10-20)
- Found: the app's resampler emitted one host sample per guest byte when the guest rate was below the host rate. RISC OS's default single channel at 48 µs (20.8 kHz) therefore played about 2.3× too fast with gaps, which made the beep and BASIC `SOUND` mostly inaudible. Rates of 4 or more channels (83 kHz and up) downsampled correctly.
- Implemented: `BoxResampler`, an area-averaging resampler shared by the app and the CLI. It applies ×2 output gain to compensate for VIDC time-multiplexing. New CLI options: `--wav` (48 kHz capture), `--swi-log`, `--dump` and `--disasm`. Sound diagnostics now report SFR, byte counts and the register log. The app's opt-in `MACARCH_DEBUG_AUDIO` hook writes Core Audio pull statistics.
- Verified: in the app, Core Audio frames delivered ≈ 2.28 × guest bytes at 48 kHz, and the beep peaks at 0.18. Elite's laser (mouse Select) produces about 0.26 s bursts peaking around 0.5. Launching is silent in Elite.
- Tests: 52 run, 0 failures (new: resampler up/down, sound DMA streaming).

## Phase 5: Lemmings and raster timing (2026-10-20)
- Found via VIDC and IOC event traces: video DMA cycle stealing was added to the clock, and the next raster line was then scheduled from the inflated time. Display lines therefore lasted 64 µs plus DMA, and 4 bpp modes ran at about 45.6 Hz instead of 50.08 Hz. Lemmings starts timer 1 at vsync (234 lines) to switch to the panel palette, and that switch landed 17 lines early: a flickering strip at the bottom of the playfield.
- Fixed: the scheduler exposes `firingTime`, and VIDC line and sound events reschedule from their due time. Regression test: `testFrameRateUnaffectedByVideoDMA`, which fails at 46 Hz without the fix.
- Diagnostics: CLI `--vidc-log N` records VIDC writes, timer GO commands and IRQ A events with frame and raster line, plus the display timing.
- Known issue: `disk-inspect` reports `!Lemmings` (a big Hugo directory) as a 2048-byte file.
- Tests: 53 run, 0 failures.

## Phase 6: JFD track-level images (2026-10-20)
- Implemented: `JFDImage`, an original loader for gzip or raw `JFDI` images, written from the container layout. Arculator's GPLv2 `disc_jfd.c` was read only to confirm field order and header bits; no code was copied. `FloppyImage` now has per-track sector layouts (`SectorHeader`: ID, size, rotational position, density, ID/data CRC flags). Raw images derive their layout from geometry. The WD1772 searches real ID fields for Read/Write Sector, Read Address, Read Track and Verify. It reports RNF for missing sectors, RNF after 6 revolutions on unformatted tracks, and CRC errors where recorded, and it honours the density latch. gzip now decodes multi-member files via the system zlib (Holed Out's first member is only the 316-byte header). `disk-inspect` understands JFD and lists non-standard tracks.
- Found: Holed Out's `DRIVER` saves a CMOS backup file into free space at track 14 side 1 sector 4, which the JFD omits, and it refuses to run from a write-protected disc. So on the original that sector was writable. Policy: a Write Sector to a missing standard sector (ID 0–4) on a formatted track creates it in the copy-on-write overlay. Unformatted tracks stay unwritable.
- Visibly working: Holed Out boots, writes `Cram`, reboots itself and reaches the title, instructions and course menus. Elite and Lemmings unchanged.
- Not supported yet: JFD delta (written-data) tables (reported by `disk-inspect` when present). Writes are not saved back to the JFD file.
- Tests: 59 run, 0 failures (new: multi-member gzip, Holed Out layout, RNF, unformatted Read Address, data CRC error, write-creates-sector).

## Phase 6: snapshots (2026-10-20)
- Implemented: versioned snapshot format, version 1. It has a `MACARCHS` magic, a JSON header (configuration, ROM SHA-256, guest time, disc references) and a zlib body with a CRC-32 and tagged per-device sections. Every component saves its own state: CPU (banked registers, prefetch pipeline), MEMC (RAM, CAM, page table, DMA pointers), IOC (timers, latches, KART), keyboard protocol, PCF8583 (CMOS, I2C phase), VIDC (registers, mid-frame raster and framebuffer, sound DMA), WD1772 (mid-command transfer state, disc overlays and added sectors), scheduler due times, and the pending input queue. `Machine.restore` builds a fresh machine, so a failed load never leaves a half-restored one. Clear errors cover: not a snapshot, unsupported version, corrupt body (CRC), ROM mismatch, and missing disc.
- Wired into the CLI (`--save-snapshot`, `--load-snapshot`, `snapshot-info`), the MCP server (`machine_snapshot_save` and `machine_snapshot_load`, with paths limited to the allowed directories) and the app (Save/Load State, Quick Save/Load, opt-in `MACARCH_LOAD_STATE` launch hook). After a state is loaded, the app stops persisting CMOS until the next power cycle.
- Found and fixed: `run(ticks:)` and `run(seconds:)` counted from the instruction overshoot, so splitting a run shifted guest time by a few ticks per split. They now count from the nominal end of the previous run (`nominalTicks`, also saved in snapshots).
- Verified: a run resumed from a snapshot matches an uninterrupted run exactly (Holed Out, 70 s + 10 s against 80 s: 150,320,288 instructions each). The restore test passes with a floppy command in flight and input pending, and a 0.5 µs timer perturbation makes it fail (mutation check). The app restores the Holed Out state at launch.
- Tests: 64 run, 0 failures.

## Phase 7: app modelled on MacBeeb (2026-10-20)
- Implemented:
  - The app was restructured on MacBeeb's design: `EmulatorHost` (emulation thread plus command queue) and a per-window `@MainActor @Observable` `MachineController` reached by the menus through `@FocusedValue`.
  - The File, Edit, View and Machine menus mirror MacBeeb's shortcuts. A customisable toolbar carries the machine lights (Caps/Num/Scroll from the keyboard LED byte, and the floppy drive light).
  - The window title shows the disc, paused and recording state; the subtitle shows the mouse-capture hint. Errors use `NSAlert`.
  - Settings window: ROM library, memory, custom key mappings.
  - Sharp, Smooth and CRT display styles. Zoom levels are relative to the frame's actual size.
  - Copy Screenshot, Paste Text, video recording (`AVAssetWriter`, timed by guest time, with audio), drag-and-drop and Finder document types.
  - Rewind with a timeline sheet. The core `Rewinder` takes a level-1-compressed snapshot plus a thumbnail every second, keeps 60, and seeks by restore-and-run.
  - App Nap is disabled while emulating.
- Tests: `RewinderTests` (a revisited moment matches the original fingerprint).
- Verified with the self-test hook: the window, toolbar and lights render; CRT scanlines show; Actual Size sets the content to the frame's display size.
- Not verified: menu enabling as seen by a focused window. A background launch can't become key, so the self-test sees the menus disabled. Interactive checks of recording, the rewind sheet and the settings window are still to do.
- Recording verified by self-test: H.264 832x576 at 50 fps with AAC sound (the boot beep is audible, peak -14.9 dB). (Audio length later fixed: see below.)
- Not carried over from MacBeeb: the debugger window, the DAP and agent-socket servers, and the Mac-layout keyboard mode. (Sparkle updates were added later: see below.)

## Phase 5 gate: four games scripted (2026-10-21)
- Repton 3 launched by the user in the app. Headless recipe found: `DIR ADFS::0.$` then `!RISC_OS`.
- Implemented: `GameSmokeTests`, an opt-in scripted smoke test per game with screenshots, frame hashes and an event log (see `docs/compatibility.md`). Also `VIDC.pointerPosition`, plus `pointer` and `pendingInput` in the CLI output.
- Found while scripting: a centre-pixel check passed on the wrong Holed Out screen. The checks now look for something specific to each screen.
- Holed Out shots: the user found the game's own instructions, which say button 2, the middle button, plays a shot. Reading the game's BASIC confirmed it (`UNTIL C%=2`), and the scripted test now plays one. The headless failures were click timing, not emulation: OS_Mouse reported the middle button correctly.
- App: trackpad and laptop support for the middle button. ⌘-click (and ⌃-click) is Menu, ⌥-click gives whichever of Menu and Adjust the secondary click doesn't, and Settings ▸ Mouse makes the secondary click Menu or Adjust. The capture subtitle names the shortcut. Button releases now match their presses.
- Open: the 10-minute play sessions.
- Tests: 70 run, 0 failures, 4 skipped (the game tests without `MACARCH_GAME_TESTS`). Game tests: 4 run, 0 failures.

## Phase 6: saving disc changes (2026-10-21)
- Implemented: `FloppyImage.saveChanges(to:)`, which writes the merged image atomically, makes it the new base, clears the overlay and updates the SHA-256; JFD images are refused. App: Save Disc Changes, Save Disc As…, "(edited)" in the title, and a Save / Don't Save / Cancel prompt before eject, insert, load state and quit (JFD: Discard or Cancel). A save resets the rewind history, whose points refer to the old disc.
- Verified: unit tests (Save As leaves the original untouched; JFD refused). The app self-test did a `*SAVE` from RISC OS onto a scratch copy of the Lemmings disc, then Save Disc Changes; `disk-inspect` lists the new file, and the corpus image's hash is unchanged.

## Phase 6: MCP attach to the app (2026-10-21)
- Implemented: the `MacArchAgent` library holds the tool table (now run through an `AgentContext`), the stdio MCP server, and an agent socket (server and client). `macarch-mcp --attach` forwards to the app, which serves its first window's machine and runs tools on the emulation thread (`EmulatorHost.sendAndWait`), then re-syncs the real-time clock. Path arguments are made absolute by the client. The window's disc name follows agent changes.
- Verified: the headless server is unchanged (create, run, capture). Attached to the live app: tools/list returns 24 tools; `machine_run` 15 s; F12 plus `*HELP MOS` typed into the app's machine and visible in the capture; `machine_create` refused; `/etc` paths refused.

## Recording audio length (2026-10-21)
- Fixed: recorded audio was timed by its sample count, so periods with no sound DMA output, plus an unflushed final buffer, left the audio short of the video. It is now padded with silence to guest time at each frame and at the end, waiting briefly for the writer instead of dropping samples. Verified: 3.674 s of AAC against 3.672 s of H.264, with the beep audible.

## Keyboard: measured UK map and Mac-layout mode (2026-10-21)
- Found: `ArcKey.forCharacter`, used for scripted typing and Paste Text, had `@`, `"`, `#` and `£` wrong. The table was rebuilt by measuring RISC OS 3.11: every key typed with and without Shift at the command line (Shift-2 `@`, Shift-3 `#`, Shift-' `"`, Shift-` `~`). New ROM test `TypingTests` checks that all printable ASCII echoes back as typed.
- Implemented: an app keyboard mode, "Mac layout (by character typed)". Character keys type what macOS reports, with the Archimedes' Shift adjusted around the key; navigation, function and keypad keys and Control combinations stay positional; Option and Caps Lock are not forwarded in this mode. Chosen in Settings ▸ Keyboard.
- Verified by the self-test, with synthetic key events through the view: Shift kept (`@`), Shift lifted (German-style Shift-0 for `=`) and Shift added (`#`) all echo correctly at the RISC OS prompt.

## Debugger window (2026-10-21)
- Implemented: a Debug menu and a debugger window (after MacBeeb's): disassembly that follows the PC with clickable breakpoints, registers and banked sets, a breakpoint list, a memory viewer (logical or physical), diagnostics, Step / Step 10 / Break / Continue. The host pauses on a breakpoint stop and publishes the reason; the window opens automatically.
- Found and fixed: a breakpoint on an exception vector never stopped, because taking an IRQ or FIQ enters the vector and runs its first instruction in one step. The debug run loop now enters the vector and stops before that instruction (`VectorBreakpointTests`). This also applies to MCP breakpoints.
- Verified by the self-test: breakpoint at &18 stops with PC=&18 in IRQ mode, Step 3 moves into the handler, the window renders, and Continue resumes.

## RISC OS 2.00 coverage (2026-10-21)
- Added: a RISC OS 2.00 boot test, and the game smoke tests parameterised by ROM. Repton 3, Lemmings and Holed Out pass on 2.00. Elite is skipped because its 1995 cover disc needs RISC OS 3 (see `docs/compatibility.md`).
- Found while scripting: the Lemmings checks were too weak to catch a run that never left the menu (on 2.00 the menu also arms timer 1, and the menu animates). They now require each screen to differ substantially from the last. The RISC OS 2 failures were all script positions and mouse scaling, not emulation.

## Packaging (2026-10-21)
- Implemented: an original icon (a RISC OS-style pointer over an icon-bar strip with a ":0" drive; layers drawn by `Tools/icon/draw.py`, compiled by actool). `tests/scripts/build-app.sh` bundles `macarch-mcp` and `macarch-cli` and signs inside out (ad hoc, or Developer ID with the hardened runtime). `scripts/release.sh` does the universal build, notarisation, stapling, DMG and zip; `NOTARISE=0` skips the credential-dependent steps.
- Built: `build/releases/0.1.0/MacArch-0.1.0.dmg` (arm64 + x86_64, ad hoc signed, not notarised). The DMG mounts with an Applications link, the signature verifies, and the universal app boots in real time.
- Not done: Developer ID signing and notarisation. These need the owner's credentials; the agent was not permitted to read another project's credential file and did not use the signing key unattended.

## Memory sizes (2026-10-21)
- Found: 512 KB and 1 MB machines stopped at a red POST failure screen under RISC OS 3.11. RISC OS 2.00 and the 2 MB and 4 MB machines booted. Physical RAM wrapped at the fitted size, but MEMC actually routes physical address bits onto the DRAM row and column lines differently for each page size. The fitted chips decode those lines for the page size that matches their capacity, and RISC OS sizes memory by selecting 32 KB pages and probing the aliasing that results.
- Fixed: `MEMC.dramOffset` models the five lines that move (row 8 and 9, column 2, 3 and 9). The mapping is applied to physical CPU accesses, CAM-mapped pages and video, cursor and sound DMA. It is the identity once the page size matches the RAM. The bit assignments were confirmed against ArcEm's description of MEMC (reference only; nothing copied). The app now offers 512 KB as well.
- Verified: `MemorySizeTests` boots 512 KB, 1 MB, 2 MB and 4 MB on RISC OS 3.11 and 2.00, and each banner reports the right size. A unit test checks the multiplexing. The 2 MB boot frame is unchanged.

## Machine models, ARM3 and ST506 hard discs (2026-10-21)
- Implemented: `MachineModel` (A305, A310, A3000, A410/1, A420/1, A440/1, A540) with per-model memory and processor choices. `MachineConfiguration` gains model, CPU and hard discs; version-1 snapshots still load as an A3000/ARM2. The snapshot format is version 2: an `HDC` section and the hard discs' paths and write counts in the header.
- ARM3: SWP/SWPB, the CP15 cache controller (identity &41560300, flush, control, cacheable/updateable/disruptive areas; privileged MCR/MRC only), and the 4 KB cache modelled for timing in MEMC. A hit costs one 24 MHz cycle, a miss a line fill plus synchronisation, and writes go through. Internal cycles run at the processor clock once the cache is on. Memory cycle costs are per machine (12 MHz on the A540).
- A540: slave MEMCs (CAM address bits 7 and 12 choose among four), up to 16 MB.
- ST506: `HD63463` from the Hitachi datasheet, wired as Acorn did (above). Found while bringing it up: ADFS reads the SSB after an Abort and then writes the next parameters from the start, so the parameter block has separate read and write pointers that every command resets. Decoded that way, ADFS's Specify block matches the datasheet exactly (OM0 &1F, OM1 &C3: DMA, parallel seek; 32 sectors, 8 heads, 1024 cylinders until the boot block is read).
- Hard disc images: raw, written straight through. `ADFSFormatter` lays out an empty old-map disc. Power-on raises `*Configure HardDiscs` to cover the fitted drives. After a CMOS reset the machine watches RISC OS write the CMOS drive byte (RISC OS 3.11 does so 7–9 s into the boot, after the Delete key is released), adds the drives, and fixes the checksum RISC OS then writes.
- App: model, processor, memory and ROM pickers in the toolbar's Model menu and the Machine menu, after MacBeeb. File ▸ Hard Disc and a toolbar item: New (formatted, 20/40/64 MB), Open and Remove per drive. The title shows the model ("+ ARM3" when fitted). CMOS profiles are per model and ROM. Loading a state switches the window to the state's model. A warning appears before rewinding past hard disc writes.
- CLI: `--model`, `--cpu`, `--hard-disc`, `--reset-at`, `hard-disc-create`. MCP `machine_create` takes model, cpu and hard_discs.
- Verified: unit tests (SWP, CP15, cache timing, configuration checks, HD63463 through DACK, formatter check bytes), ROM tests (A540 16 MB, ARM3 cache and speed, hard disc round trip on both ROMs, ARM3 A440 snapshot determinism), and the app self-test (an ARM3 A440 with a new hard disc: title, menus, `*Cat :4`). Full suite: 95 tests, 0 failures.

## The A5000 family: new I/O, IDE and ARM250 (2026-10-21)
- Implemented: models A5000 (ARM3), A3010, A3020 and A4000 (ARM250: SWP, no cache, 12 MHz memory). `SuperIO` holds the 82C711 glue (PC ports in IOC bank 1, configuration mode, printer, the serial presence check) and the IOEB (device ID 5, monitor ID with horizontal sync, video clock select, A3010 joystick port). VIDC divides a selectable base clock (24, 25.175 or 36 MHz).
- `FDC765`: the 82C711's floppy core, implementing the command set RISC OS uses (Specify, Sense Drive/Interrupt Status, Recalibrate, Seek, Read ID, Read/Write Data, Format, Version, Configure, Lock). It shares the WD1772's drive array, so inserting, ejecting, snapshots and the app are unchanged.
- `IDEController`: the AT task file (CHS through Initialise Device Parameters, read/write/verify sectors, format, identify, recalibrate, seek), driven by programmed I/O. Its interrupt is IRQ B bit 3.
- Found while bringing it up:
  1. RISC OS addresses the 82C711 with address bit 21 clear (&3010000); IOC decoding now needs bit 21 only for IOC's own registers when the new I/O is fitted.
  2. ADFS detects a disc by its index pulses, which arrive on IRQ A bit 2.
  3. ADFS probes 500 kbit/s first, so a double-density disc must not be readable at that rate.
  4. Reading the result phase clears the floppy interrupt. Without that, an IRQ storm hung the machine.
  5. Terminal count is decoded from the DACK address, and ADFS asserts it between sectors to end a multi-sector read early (its FIQ handler reads &302A000 when its buffer list runs out). Without that, the next sector's DMA ran into page zero and the games crashed.
- Formatter: also lays out IDE drives (512-byte sectors, no ST506 parameters). CMOS: `*Configure IDEDiscs` (bits 6-7 of the drive byte) is set for fitted IDE drives.
- Verified: `NewIOTests` (A5000 floppy round trip, IDE round trip on the A5000 and A3020, A3010 boot, A5000 snapshot determinism mid-way through a floppy read), `VIDCClockTests`, all four games on the A5000, and the app self-test as an A5000 with a new IDE disc. Full suite: 104 tests (game tests included), 0 failures. Speed: about 38x real time for ARM2/ARM250 machines, 12x for ARM3 machines (which execute about three times as many instructions per guest second).

## Fix: stale hard disc count in CMOS (2026-10-21)
- Reported: the first A440/1 start took a long time to reach the desktop, and its hard disc icon gave an ADFS error. Creating a new hard disc fixed it.
- Cause:
  - The app self-test had run as an A440 in the user's own settings and saved a CMOS profile configured for one hard disc, then removed its disc. So the "first" boot had HardDiscs 1 and no drive.
  - ADFS then waits on the missing drive (the desktop arrives at 45–60 s instead of under 20) and shows a drive icon that only gives errors.
  - Removing a hard disc in the app would have done the same, because power-on only ever raised the configured count.
- Fixed:
  - Power-on and reset now set the ST506 or IDE count to exactly the drives fitted, on machines with a hard disc interface (`CMOSDriveCountTests`).
  - Self-tests now use their own defaults domain and a temporary support folder, so they never touch the user's settings, CMOS profiles or hard discs.

## Debugger, profiler and MCP server, after MacBeeb (2026-10-21)
- Debugger (`ArchimedesCore/Debug`):
  - Costs nothing when unused: the CPU calls it only while `debugHooks` is on.
  - Breakpoints on execute, read, write or any access, over address ranges, with conditions, hit counts, a processor mode or a log message. Watchpoints stop after the instruction that made the access.
  - Steps: into, over (BL and SWI), out (to R14, or the end of an interrupt), run to an address, next scanline, frame or interrupt.
  - Step back and reverse continue replay rewind windows with an observer. Hard disc writes are suppressed during the search.
  - An expression language for conditions and addresses; symbol files (`name = &x`, `EQU`, `*`, nm format) plus built-in vector and I/O names; SWI names in the disassembly.
  - Trace buffer; hardware state for every device; a profiler by page-sparse counters, grouped by nearest symbol, with interrupt share.
- Rewind:
  - A point every 0.5 s (120 kept). Live keyboard and mouse input is logged and replayed exactly (`RewindReplayTests`), so stepping back lands on the same instruction the machine actually ran.
  - Register and memory edits take a keyframe.
- Screen text: 8×8 display cells are matched against the system font, which is found in the ROM, giving text for agents and `--screen-text`.
- Idle detection for `run_until_idle`:
  - Fires when a user-mode OS_ReadC, OS_ReadLine or Wimp_Poll is still blocking after a settling period, or when INKEY polls continue while the screen is unchanged.
  - Requires no queued input and no disc activity.
  - Found: a PC-span heuristic fired in boot delay loops, OS_ReadLine's nested OS_ReadC must not count, and the "Initialising" splash makes short Wimp_Poll spells.
- MCP server (39 tools, after MacBeeb's tool set):
  - Headless, it boots its own machine from `--rom`, `MACARCH_ROM` or the app's ROM.
  - With `--attach`, the app serves a thread per client on its socket.
  - `set_real_time` holds the machine between calls, and the title shows "(Held by AI Agent)".
  - `run_command` types at 40 ms per key (12 ms garbled the text).
- App:
  - Debugger window rebuilt after MacBeeb's: toolbar with F6/F7/F8 and back, disassembly with heat bars, memory with change highlighting and editing, and CPU/Breakpoints/Hardware/Trace/Profile/Log tabs.
  - Screen inspection on hover.
  - MCP menu: Connect an AI Agent…, and an Activity Log of every call. Toolbar agent light.
- Verified:
  - `DebuggerTests`, `DebuggerROMTests` and `RewindReplayTests`; full suite 114 tests, 0 failures.
  - Headless MCP: boot to desktop, `*Echo`, BASIC `PRINT 6*7`, breakpoints, step back, profile.
  - Attached to the app: all 39 tools listed, hold, run_command, a breakpoint at &18, reverse continue, power cycle to an A5000.
  - App self-test of the debugger window and both MCP windows.
- Not done at the time: a DAP/VS Code adapter and an `assemble` tool (both added next).

## ARM assembler, debug adapter and VS Code extension (2026-10-21)
- Assembler (`ArchimedesCore/Assembler`):
  - Covers ARM2/ARM3/ARM250, in BBC BASIC V syntax as a file of its own, with some ObjAsm spellings.
  - Two passes, a literal pool, ADR/ADRL, INCLUDE/INCBIN.
  - Reports every error with its file and line, plus warnings (for example MUL with Rd = Rm).
  - Labels and the source line of every instruction go into the symbol table, which now keeps source lines. `file.s:12` works wherever the debugger takes an address. Re-assembling a file replaces its lines.
- Disassembler:
  - Prints `OS_WriteI+'A'` and full coprocessor syntax, so everything it prints assembles back.
  - `AssemblerTests` round-trips 20,000 random words: disassemble, assemble, disassemble again, same text.
- MCP `assemble` (40 tools): it gets to the `*` prompt (F12, or QUIT from BASIC), loads the code at its ORG, adds the symbols and runs it with `*Go`. Disassembly and lookup_symbol show source lines.
- Debug adapter (`MacArchAgent/DAPSession`, `DAPServer`):
  - Modelled on MacBeeb's, on localhost port 3200.
  - Launch assembles `source` (or loads `program`), can switch `model` or insert a `disc`, then runs it after configurationDone, stopping on entry if asked.
  - Breakpoints: source, function (expressions), instruction and data (a whole word).
  - Navigation: stack trace (PC, and the caller when R14 follows a BL), scopes (registers, flags and mode, banked registers, hardware), setVariable, evaluate with hover memory, read/write memory, disassemble with source lines.
  - Stepping: next/in/out/back and reverse continue.
  - Output: log points, and what the program prints (as stdout).
  - The app serves it for the first window; Settings ▸ Debugging turns it on and off and sets the port.
- VS Code extension (`Tools/vscode-macarch`): a language for `.s`/`.arm` with a grammar, the `macarch` debugger type, and F5 to assemble and run the file in the editor. It starts MacArch if needed. It packages with vsce.
- Fixed: text captured from OS_WriteI was doubled, because RISC OS's handler calls OS_WriteC itself.
- Verified:
  - `AssemblerTests` (7).
  - `DAPTests` (framing; an end-to-end session on a headless running machine covering stop on entry, a source breakpoint moved to the next line with code, evaluate, hover, step over/in/out/back, setVariable, memory, disassembly, program output; assembly errors failing the launch).
  - `test/smoke.js` against the real app over TCP.
  - MCP `assemble` with a breakpoint on `hello.s:20`.

## The wider collection: formats, hard discs from files, monitors (2026-10-21)
- Swept 23 new images (results in docs/compatibility.md).
- Floppy formats:
  - ADFS D/E images up to four tracks short of 800K are accepted when they hold an ADFS directory; the missing sectors read as zeroes (three Krisalis images lack their last track).
  - HFE version 1 (`HFEImage`, written from the HxC format's published layout): the MFM cell stream of each track is searched for the A1 sync marks, and ID fields and data fields are decoded with their CRCs into the same per-track sector layouts JFD uses. Like JFD, read-only for saving. `FloppyFormatTests` builds an HFE in memory with a missing sector and a bad data CRC.
- Hard discs from files (`ADFSHardDiscBuilder`, `ZipArchive`):
  - Lays out a formatted old-map drive with sorted 2048-byte "Hugo" directories (attributes in byte 25, as on a real D-format disc), files contiguous from &E00, the free space map and directory check bytes recomputed. Directories are dated by their newest file.
  - Sources: ZIP archives (stored and deflate, with the Acorn "ARC0" extra field for load/exec/attributes; names Latin-1 unless flagged UTF-8) and folders (`,xxx` filetype suffixes).
  - App: Hard Disc ▸ New Hard Disc from Files…; CLI: `hard-disc-create … --from`.
  - `HardDiscBuilderTests`: zip parsing, layout check bytes, rejection of long names, full directories and file/directory clashes, and RISC OS 3.11 reading a built drive (`*Type`, a 70 KB `*Load` compared byte for byte).
- Monitors: `MonitorType` (standard, multisync, VGA). The A5000 family's IOEB reports it on the monitor ID lines (&E with sync on bit 0; &B with sync on bit 2; &E without sync), so RISC OS 3.1's auto-detection picks a 640 x 480 desktop after a CMOS reset. In the Machine menu and Settings (per model), and in MCP power_cycle (`monitor`).
- ADFS inspector: big directories' directory bit is byte 25, not the old name-bit (nested directories on D-format discs were listed as files).
- Agent tools: the mouse tool steers the pointer's tip (`VIDC.pointerHotspot`, the first visible pixel of the pointer image; RISC OS pads its arrow by about 21 pixels), and screenshot reports the frame size and scale. CLI: `--hardware` prints the debugger's hardware sections, `--watch-page ADDR` logs MEMC remaps of one logical page.
- Investigated, not emulation bugs: Master Break/Repton 2 load times (cycle counts match the ARM2), Magnetic Scrolls on RISC OS 3.11 (screen memory; see compatibility).

## Welcome screen and ROM import (2026-10-21)
- `ROMImporter` (core): scans files, folders (a few levels) and ZIP archives (one level of nesting) for RISC OS ROMs.
  - Layouts: a whole image; a set of files as consecutive slices in name order (both of the user's dumps are four slices, not byte-wide chips); four byte-wide or two halfword-wide chips interleaved, in every order.
  - Checks: the reset vector is a branch; an "Arthur"/"RISC OS" version string reads correctly; the image is the size that version shipped as (512 KB, or 2 MB for RISC OS 3), so the first 512 KB slice of RISC OS 3 alone is not mistaken for a ROM. Slices whose name order doesn't start with the kernel are accepted only in an order that gives a known dump; otherwise the user is asked to name them in order.
  - Known-good table: SHA-256 of the two dumps checked here (RISC OS 3.11 and 2.00). Neither ROM carries a word sum or CRC32 the importer could check (tried).
  - Rejections say why: part of a larger ROM, one chip of a set, no version string, wrong size.
  - `install` writes the combined image into Application Support/MacArch/ROMs, named after its version, deduplicated by hash.
- App: `ROMLibrary` (scan in the background, install, replace an external entry with the copy, choose a default preferring the newest), a welcome screen (`WelcomeView`: hero, model/memory/monitor, drop zone with animated border, results, ROM cards with known-good/recognised badges and model suitability, Switch On), the ROMs window (MacArch ▸ ROMs…, Machine ▸ ROM ▸ Add ROMs…, Settings), and drops on a running window offered as ROMs when they aren't discs or states.
- Tests: `ROMImporterTests` (chips in a scrambled order, halfword pairs, slices in and out of order, a zip of chips, rejections, install twice, the user's sets known). Self-test hook `MACARCH_SELFTEST_IMPORT="a|b"` adds ROMs as a drop does and writes a report.
- Fixed: dragging files over the welcome screen pegged WindowServer at 100% (measured; MacArch itself was near idle). The drop zone's marching-ants border redrew the window 30 times a second while hovering, and the blurred material cards had to be re-blurred each time. The border is now static (it changes colour on hover) and the cards are plain translucent fills; hovering costs nothing measurable. `MACARCH_SELFTEST_HOVER=1` holds the drop zone in its hover state for measuring.

## Sparkle updates and the About box (2026-10-22)

- Sparkle 2 (SwiftPM), as in MacBeeb: `Updates` starts the standard updater only when the bundle has both `SUFeedURL` and `SUPublicEDKey` and isn't self-testing. MacArch ▸ Check for Updates… is disabled otherwise.
- `tests/scripts/build-app.sh` embeds Sparkle.framework in Contents/Frameworks, adding the rpath `@executable_path/../Frameworks`. It signs Sparkle's helpers, then the framework, then the tools and the app, and writes `SUPublicEDKey` when SPARKLE_PUBLIC_KEY is set.
- `scripts/release.sh` builds `appcast.xml` from the published feed plus the new zip, signed with the key in the login keychain under the account `macarch`. `--publish` tags and creates the GitHub release with the DMG, the zip and the appcast.
- About MacArch links to github.com/JamesRandall/macarc and jamesdrandall.com.
- Verified: the ad hoc bundle builds, passes `codesign --verify --deep --strict` and launches with the framework embedded. Not yet verified: a signed release, the appcast, and an update being installed.

## What's New (2026-10-22)

- `WHATSNEW.md` at the repo root holds the release notes, one `## VERSION [— DATE]` section per release. `build-app.sh` copies it into Resources as `WhatsNew.md`, and `swift run` reads the repo's copy.
- `WhatsNew` parses it and records the version run (`whatsNewSeen`). On the first launch after an update, the first machine window opens the What's New window, with releases newer than the last version run (and not newer than this build) marked New. Help ▸ What's New in MacArch opens it any time. A fresh install records the version without showing it.
- `scripts/release.sh` requires the version's section. It writes it to `notes.md` for `gh release create --notes-file`, and beside the zip as `MacArch-VERSION.md` for `generate_appcast --embed-release-notes`.
- Verified:
  - A test appcast has `<description sparkle:format="markdown">` with the notes, signed with the `macarch` keychain key.
  - Self-test (`MACARCH_SELFTEST_WHATSNEW=0.0.9`) opens the window with 0.1.0 marked New. With 0.1.0 as the last version, it doesn't open.
  - The Help menu has the item.

## More games; short images' last track (2026-10-22)

- Short ADFS images (a track or more under 800K) now have the missing tracks unformatted: reads give "sector not found", and a format or write puts them back (`FloppyImage.formatSector`, used by both controllers' format commands). They were read as zeroes, which defeated Play It Again Sam 1's protection: Hostages verifies that the boot disc's last track is unformatted, and the zero-filled track passed, so it dropped into BASIC. Pacmania, Speedball 2 and Sim City (also short) still pass.
- Found while testing, not emulator faults (see docs/compatibility.md): launching by `ADFS::0` instead of the disc name, swapping a disc before the game asks, and running Xenon 2's launcher before the Filer has seen its sprites.
- New collection tests: Apocalypse, Gods, Cannon Fodder, Conqueror, Hostages, No Excuses and Rotor, Xenon 2, Stunt Racer 2000. All 15 collection tests pass.
- Doom Trilogy installs from a hard disc built from its ZIP, but Doom+ needs Acorn's `!System` (BorderUtils) to start.
- Release test builds need `-Xswiftc -enable-testing` with Xcode 27's SwiftPM (a clean build otherwise fails to resolve the ArchimedesCore module); the documented commands include it.
