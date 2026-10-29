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
- About MacArch links to github.com/acorn-playground/macarch (formerly JamesRandall/macarc) and jamesdrandall.com.
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
- Doom Trilogy runs (Ultimate Doom's demo, `testDoom`) from a hard disc built from its ZIP plus Acorn's !NetUtils, which provides the BorderUtils module Doom+ needs on RISC OS 3.1.
- Release test builds need `-Xswiftc -enable-testing` with Xcode 27's SwiftPM (a clean build otherwise fails to resolve the ArchimedesCore module); the documented commands include it.

## Adding files to an existing hard disc; imploded ZIPs (2026-10-22)

- `ADFSHardDiscWriter` adds files to an existing old-map drive (what MacArch makes, and !HForm's old-map option). Each file takes the first big enough area in the free space map, aligned to the sector size. Missing directories are made, a file of the same name is replaced and its space freed, and each changed directory's master sequence number goes up. The work is done on a clone of the image, which then takes its place, so a failure leaves the drive as it was. New-map ("E") drives are refused with a message.
- App: Hard Disc ▸ Add Files to Hard Disc… for a fitted drive. It takes several ZIPs or folders at once, says which files would be replaced, then restarts the machine: RISC OS keeps the map and directories in memory, so writes from the old machine are stopped first. New Hard Disc from Files… also takes several sources now. Dropping a ZIP or folder that isn't a ROM on a running window offers to add it to a fitted drive, or to make a new one; several can be dropped at once.
- Compaction (`compact:`), offered when there's room but not in one piece. As *Compact does, files and directories slide down in address order to close the gaps. Directory entries, and moved directories' parent pointers, follow them, and the free space becomes one area. The copies are made lowest first, each to a lower address, so nothing is overwritten before it has moved. Drives whose boot block lists defects are refused. Empty files are never freed, since RISC OS may have given them no space.
- CLI: `macarch-cli hard-disc-add FILE SOURCE... [--compact]`.
- ZIP method 6 (implode, PKZIP 1) is expanded (`ZipImplode`, from the APPNOTE), and every member's CRC is now checked. Zarch's desktop version (`Zarch (…)(Better desktop integration).zip`) needed it.
- Tests:
  - `HardDiscBuilderTests` covers ST506 and IDE drives: planning changes nothing, adds, replacements, new directories, sector alignment, freed space merging back, conflicts, and a drive left unchanged when an add fails.
  - RISC OS reads replaced and added files, then makes a directory, saves into it and deletes a file. The drive it leaves can still be added to.
  - `testDoom` now builds the drive from Doom alone and adds !NetUtils afterwards.
  - `testZarchFromZip` runs the imploded archive.
  - `testCompactingMakesRoom` (ST506 and IDE) uses a drive with two 3 MB gaps. A 5 MB file is refused as fragmented, then fits once the drive is compacted. Every file keeps its contents, the free space is one area, and moved directories point at their moved parents. Planning changes nothing.
  - `testRISCOSUsesCompactedDrive`: RISC OS reads a moved file in a moved directory, makes a directory and saves into it there, and deletes a file.

## Resizing hard discs (2026-10-23)

- `ADFSHardDiscWriter.resize` changes an old-map drive's size, keeping its sector size. Disc addresses are byte offsets whatever the drive's shape, so files don't move. The changes are: the map's size field and free space (clipped, or extended with a new area at the end and merged), the boot block's disc record (sectors per track, heads, size, plus the park address for ST506), and the file's length. It works on a clone, as adding does. Shrinking below the highest file is refused (`tooSmall`, with the compacted size), unless `compact` closes up the gaps first. `usage` reports size, free space, the highest used address and the compacted size.
- App: Hard Disc ▸ Resize Hard Disc… for a fitted drive. It picks from New Hard Disc's sizes for the drive type, shows the current size and usage, offers to compact when shrinking needs it, and restarts the machine. CLI: `hard-disc-resize FILE CYLINDERS HEADS [SECTORS] [--compact]`.
- Tests:
  - `testResizeGrowsAndShrinks` (ST506 and IDE): grow, then add a file bigger than the old drive. The boot block gives the new geometry, contents are unchanged and the free space is right. Shrinking is refused, leaving the drive unchanged, then succeeds with compaction. Sizes too small even when compacted, and changes of sector size, are refused.
  - `testRISCOSUsesGrownDrive`: RISC OS saves 3 MB into a 20 MB drive grown to 40 MB, past the old end.

## Copying a drive between ST506 and IDE (2026-10-23)

- An ST506 drive (256-byte sectors) can't be fitted to an IDE machine (512-byte sectors), or the other way round. Open Hard Disc said only that the image wasn't recognisable. Now it recognises the other kind (from the boot block's disc record) and offers to copy it. The copy goes on a new drive of the right kind beside the original, "NAME (IDE).hdf", sized to the smallest preset that holds the files. It is fitted instead, and the original is left alone.
- `ADFSHardDiscWriter.contents` reads a drive's files (data, load and execution addresses, attributes), its directories (empty ones included) and its disc name. `copy` builds a new drive from them. `ADFSHardDiscBuilder` takes `directories:` so empty directories survive.
- CLI: `hard-disc-copy SOURCE DESTINATION [CYLINDERS HEADS [SECTORS]] [--ide]`.
- Tests: `testCopyST506DriveToIDE` checks files, addresses, attributes, the empty directory and the name, and an A5000 runs the copied `!Run`. Also checked by hand: the user's A440 drive (Doom installed, !NetUtils, !Wolf; 114 files, 22 directories) copied to IDE, and Doom played from it on an A5000.

## Turbo ARM3 (2026-10-23)

- New processor choices, ARM3 ×2 (48 MHz) and ×4 (96 MHz), wherever an ARM3 fits. With the cache on, a cache hit or internal cycle costs 1/2 or 1/4 of a 24 MHz tick. `MEMC.processorCycles` keeps the remainder in `subTicks`, so timing stays exact and deterministic. The CPU charges internal cycles through the new `ARMBus.internalCycles`. Memory cycles (cache misses, writes, I/O) and every device keep real time, so games' timers and the RISC OS clock run as before. Only turbo machines save `subTicks`, so other snapshots keep their layout.
- `MachineModel.defaultCPU` now prefers the ARM2, else the first choice, as the A540 and A5000 have three choices now.
- Tests:
  - `testTurboARM3IsFasterButKeepsRealTime`: a BASIC loop runs about 1.65 and 2.5 times faster, with RISC OS's TIME agreeing to within 3 cs across all three speeds.
  - The ARM3 A440 snapshot test also runs ×4.
- Measured by hand: Doom's attract demo on a 4 MB A5000 runs at 4.1 frames/s (ARM3), 5.8 (×2) and 9.3 (×4).

## Configure Machine window (2026-10-23)

- `ConfigureMachineWindow` (Machine ▸ Configure Machine… ⌥⌘C; clicking the toolbar's model button, which still shows the quick menu when held) follows MacBeeb's Hardware Expansions window.
  - Sections with titles and explanations. Choices are cards with SF Symbols, descriptions and badges (ST506/IDE, RISC OS 3, "Faster than real", "As sold", ROM size). The selected card is outlined, and the one in use is marked Fitted.
  - The hardware is a draft: an orange restart bar offers Revert and Restart Machine, which calls `setHardware` once. Choosing a model brings back that model's remembered processor, memory and monitor, and a suitable ROM if the current one isn't.
  - Unsuitable ROMs are dimmed with the reason.
  - Hard disc rows show usage (from `ADFSHardDiscWriter.usage`) and offer New, Open, Add Files, Resize, New from Files and Remove. These act straight away, and wait while a different model is pending.
- Self-test: `MACARCH_SELFTEST_CONFIGURE=1` (or a model name, to show it chosen) captures the window, top and scrolled to the end. Checked on an A3000, an A440 with a hard disc, and with an A5000 pending.

## A540 slave MEMCs, checked against the hardware references (2026-10-23)

- Sources:
  - VLSI's MEMC databook (VL86C110, in the VTI ARM Databook 1990, pp. 4-8 to 4-13): "A(7) specifies whether the Master or Slave Address translator is being accessed", translation compares every entry at once, and the translator is scrambled by page size changes.
  - Theo Markettos's notes on the A540's decoding PAL: the master at &2000000–&23FFFFF, the slaves from &2400000, with A7 and A12 selecting translators.
  - The StarDot thread on MEMC1a, from the A540 schematics: the PAL makes a separate A7 and A22 for each MEMC, and the MEMCs' aborts are ANDed.
  - Arculator, read for behaviour only.
- MEMC now models the arrangement explicitly (`slaveMEMCs`, `memcCount`), A540 only:
  - A7 and A12 choose the MEMC for a CAM write at every page size. Before, this was only with 32 KB pages, as in Arculator, but the PAL can't know the page size.
  - A write for a MEMC that isn't fitted is lost. Before, it wrapped onto the master's pages.
  - Each MEMC's pages lie in its own 4 MB.
  - Physical addresses choose the MEMC by bits 22–23. With none fitted there, reads give &FF (an assumption shared with Arculator; the references don't say) and writes are lost. Before, these wrapped into fitted memory.
  - Other machines keep one MEMC, whose physical space repeats.
- RISC OS 2.00's 8 MB on a 16 MB A540 is settled as the ROM's own limit. Logging its CAM writes shows it never addresses A12's MEMCs. Over 4 MB its Window Manager 2.00 raises "Too many pages in this machine!", and the error path then unstacks from R11 = "TASK" and takes an address exception.
- The Configure window's Memory section says so for the A540.
- Tests:
  - `testA540SlaveMEMCs`: A7 to a slave at 32 KB and 4 KB pages, an absent slave's CAM write ignored and its logical page aborting, unfitted physical space reading &FF and ignoring writes, and a single MEMC wrapping round.
  - `testA540MemorySizesBothROMs`: both ROMs at 4, 8 and 16 MB, checking the banner, pages mapped and address exceptions.
- Fixed: an 8 or 16 MB A540 started at the Supervisor prompt, and a desktop started by hand was in mode 0 (black and white). Its CMOS was empty. A first boot holds Delete to reset CMOS, but RISC OS clears memory before reading the keyboard, so 4 seconds was too short (it needs under 5 s at 8 MB and under 8 s at 16 MB). Now keys are held 2 s plus 0.5 ms per KB above 4 MB, so smaller machines are unchanged. A CMOS file RISC OS never set up (`Machine.cmosNeverConfigured`: fewer than eight configuration bytes) is reset again at the next start, which repairs profiles saved while this was wrong. Test: `testA540FirstBootResetsCMOS`.

## Econet and the Network Studio (2026-10-24)

- Research first (`docs/econet-notes.md`): the ADLC's place (&33A0000, IOC bank 2, sync; registers a word apart), its interrupt (FIQ bit 2 only), the station number in CMOS byte 0, how RISC OS detects and drives the chip (from Acorn's Econet module source, Apache-2.0, read for facts), the protocol, AUN, and Acorn's Level 4 File Server.
- MacArch is GPLv3 (`LICENSE`, added to every commit), as MacBeeb is, so MacBeeb's Econet work came across: its MC6854, line, trace, lockstep host and Network Studio, adapted. Network time is 24 MHz ticks (a BBC cycle is exactly 12), with MacBeeb's 16 µs quantum and line delay, so the two apps' lines can be joined later without rounding.
- Core (`Econet/`): `MC6854`, `EconetModule` (IOC bank 2, FIQ), `EconetLine` (stations behind an `EconetInterface` protocol, so something other than a local machine, such as a link to MacBeeb, can plug in), `EconetTrace`, and `EconetNetwork` (lockstep on one thread, for tests). `MachineConfiguration.econetStation` fits the module and sets CMOS byte 0 (at power-on, reset and during a CMOS reset).
- Two ADLC fixes RISC OS needed, which MacBeeb's DNFS and ANFS didn't:
  - TDRA and RDA are levels: IRQ stays on while either wants serving with its interrupt enabled. RISC OS clears TX status as it raises RTS to turn the line round, then enables TIE and waits for TDRA, which is already up; as an edge, it never interrupted.
  - A station hears its own transmission: RISC OS leaves its receiver running while it sends a scout, and takes idle (15 one-bits) as "not listening". Without hearing its own flags the line looked idle the moment the scout ended.
- RISC OS reads DCD (no clock) from a status copy its interrupt handler keeps, so a machine started off the network keeps saying "no clock" once plugged in. Stations are on the line from power-on, as cabled machines are.
- Tests (`EconetTests`): the station number from CMOS (`Econet_ReadLocalStationAndNet`); `Econet_DoTransmit` to an `Econet_CreateReceive` block, scout/ack/data/ack in the trace; RISC OS 2.00 and 3.11 each way; "not listening" and "no clock"; a run repeats frame for frame. (SWIs by number: RISC OS 2 starts in Caps Lock.)
- App: `NetworkHost` runs the stations' `EmulatorHost`s (no threads of their own) in lockstep, paced by the wall clock; commands and readiness are looked at only when something asks for attention. `MachineController` has a station mode (its hardware, discs and CMOS belong to the network, through `StationOwner`); `MachineScreen` is the machine window, shared by standalone machines and station windows. The studio: start page with templates, canvas, tiles, focus, traffic and inspector, as MacBeeb's. Five machines run at real time in a release build on an M-series Mac.
- Then (same day):
  - **Level 4:** `ADFSDiscReader` reads ADFS D and E floppies (and JFD/HFE), so `Level4` builds a server hard disc from the user's Level 4 disc, with a boot file that starts !Server; `CMOSSetting`s keep the server booting from drive 4 with 1024K of RMA. The studio's Set Up Level 4… does it, choosing a RISC OS 3 ROM. `Level4Tests` boots a server and a client: `*I AM SYST` then `*CAT` lists the server's disc. Floppy images also work as sources for New Hard Disc from Files… and `macarch-cli disk-files` (with `--extract`).
  - **Agents:** `MachineDirectory` (the app's `AppMachineDirectory`) gives every tool a `machine` argument and adds the network tools, after MacBeeb's. A station's tool that runs time runs the whole network in step there and then (`NetworkHost.runInline`). The agent socket also starts when a network opens. Checked end to end: a station sent another a message through MCP calls alone.
  - **Threads:** `LockstepWorkers` (core, after MacBeeb's): spare threads run some stations each quantum, spinning between quanta and parking when idle. The network adds a thread when it falls short of real time and keeps it only if it helps. The School Classroom flat out: 6.4× real time on one thread, 9.3× on three. `EconetTests.testThreadsDontChangeTheRun`: three threads give the same frames and screens as one.
  - **macOS 26:** MacArch now targets macOS 26 with Swift tools 6.2, as MacBeeb does (still Swift 5 language mode), so its toolbars take the system's current look.
- Not yet: joining MacBeeb's networks (AUN, or a shared line between the apps).

## Disc contents: editing floppies and hard discs from the Mac (2026-10-27)

- After MacBeeb's Disc Contents window, with hard discs too. Core (`Media/ADFSStore`, `ADFSVolume`, `ADFSMaps`, `ADFSHostFiles`): ADFS D, E and F floppies and old- and new-map hard discs (up to 512 MB), read and written through `ADFSVolume`: save, make directory, rename, set info, delete, disc name and boot option. New-map allocation is first fit, then several fragments under one id. Every change is buffered, so one that fails leaves the disc alone, gets a new disc ID, and records each 256-byte block it replaced for undo.
- Mac files: `,xxx` suffixes, `,llllllll-eeeeeeee` load and exec addresses, `.inf` files, known extensions as filetypes and `.bas` text tokenised. Dragged-out files carry `,xxx` names.
- Reaching RISC OS: a floppy's change waits until the drive has been idle 2 s, goes into the image's changes (kept by Save Disc Changes) and raises the disc-changed latch. A hard disc's waits until the machine stops writing, holds its writes, edits the file and restarts the machine.
- App (`DiscContents/`): one window per machine with a drive picker, table, drag in and out, Get Info, New Directory, Export and undo; File ▸ New Disc makes blank E or D floppies.
- Then L, M and S floppies: the same old map with the root at &200 and the old 1280-byte directories (47 entries). Their layout was taken from a disc RISC OS 3.11 formatted (`*Format 0 L`) and wrote in the emulator: the tail is name, parent, title; the check byte is the same sum over the tail from &4CC; access is R, W, L and D in the top bits of the name's first four characters (public access isn't kept), and an entry's last byte is the directory's sequence number when it last changed. Names there are ASCII (Mac spaces come in as `_`). And unlike D, E and F, an L disc's sectors run through all of side 0 and then side 1 (RISC OS's `*CDir` put a directory at disc sector &1D on side 0, track 1), though .adl files still alternate sides track by track. New Disc offers L; Save As suggests .adl.
- Then copy protected discs. The window used to read the whole disc and fail on the first odd sector; now it reads sector by sector, and only files on odd sectors fail (a folder's export leaves them out and says so). A sector is ordinary if it's there once on its track, the right size, on the right cylinder and without CRC errors. Writing is the risk: Holed Out, Stunt Racer and most short ADFs have their protection tracks marked free (on Holed Out and Stunt Racer disc 2, all the free space is), so `ADFSStore.unusableAreas` gives every track with anything odd on it, and both maps' allocation keeps clear of those without recording anything on the disc. Free space is reported without them. Tests: a short E and D disc only use what's there; Holed Out and Stunt Racer disc 2 fill (after a deletion) with their odd tracks and other files unchanged; `testHoledOutAfterDiscEditing` plays Holed Out to a shot after an edit rewrote its root and map. Repton 3's map has an empty free area at the disc's end, which is now ignored as RISC OS does.
- Tests (`DiscEditingTests`): every disc in `top25/` checks out clean (43 E, 4 D, 1 F); RISC OS 3.11 and 2.00 see changes to E and D floppies live and their own writes leave the disc sound; RISC OS reads a changed hard disc after the restart.

## The VS Code extension moves to its own repository (2026-10-27)

- `Tools/vscode-macarch` is now github.com/acorn-playground/vscode-macarch, with its history (git subtree split), as MacBeeb's extension went to vscode-macbeeb. It's GPLv3, published as AcornPlayground's `macarch-debug`, with MacArch's icon, a changelog, and a workflow that publishes to the Marketplace (and Open VSX) when a `v*` tag is pushed. The README, Settings ▸ Debugging and the smoke test's command point there.

## Follow the Mac pointer (2026-10-28)

- A second mouse mode, beside capturing: RISC OS's pointer follows the Mac's, which stays free. `PointerFollower` (core) steers with ordinary mouse counts, as the agent `mouse` tool and the Classics' icon bar clicks do: once a frame it compares the target with the hardware pointer's tip (`VIDC.pointerHotspot`), sends the counts to close the gap, waits for RISC OS to take them, and learns pixels per count from how far they went (so modes and MouseStep don't matter). It steers for 50 frames after the target last moved, then lets go, so programs that move the pointer (MOUSE TO, OS_Word 21) aren't fought. `VIDC.pointerShown` says whether the pointer is on (some of it drawn, its tip in the display area); while it's off, the Mac's movements go through as counts, for games that read the mouse themselves.
- App: `AppSettings.mouseMode` (Settings ▸ Mouse, Machine ▸ Mouse). The view sends the frame pixel under the Mac pointer (clamped to the picture) with each move and drag, hides the Mac's pointer over the display area while RISC OS's is on (over VIDC's border it shows, and RISC OS's waits at the display's edge), and passes clicks straight through. Leaving the view or the window lets go.
- Tests (`PointerFollowerTests`): on RISC OS 3.11 and 2.00, at the desktop and in BASIC's MODE 13 with MOUSE ON, the pointer reaches corners, the middle and moves of a few pixels to within a pixel in half a second; there's no pointer at the `*` prompt; and MOUSE TO isn't undone afterwards.

## ArcLibre included, and 4 MB ROMs (2026-10-28)

- ArcLibre 0.8 (`Apps/MacArch/Resources/ArcLibre`, from ~/code/riscos-oss's `dist/`, with its Apache-2.0, FPEmulator and Squash licences, LICENSING.md and a README) is copied into the app by `build-app.sh` and added to the ROM list at launch (`AppSettings.addBundledArcLibre`): installed into Application Support/MacArch/ROMs unless the same image is already listed, replacing an older ArcLibre MacArch put there. Acorn's ROMs stay the default (the newest version string wins, and "RISC OS" sorts after "ArcLibre"); with none, ArcLibre is. Removing it from the list records its SHA-256 so it isn't put back. `scripts/update-arclibre.sh` refreshes the files from an ArcLibre build.
- ArcLibre's *FX 0 text says "compatible with RISC OS 3.11", which `findVersion` would read as RISC OS 3.11, so it's recognised first by its kernel's *Help title ("ArcLibre<tab>0.80 (28 Oct 2026)"): "ArcLibre 0.80 (28 Oct 2026)". `ROMImage.isOS` covers it wherever RISC OS and Arthur were checked; it's 2 MB like RISC OS 3, and offered only for the machines before the A5000 (no IOEB drivers). Classics, which ask for RISC OS 2 or 3, don't take it.
- `ArcLibreTests`: recognised and known; from a CMOS reset (Delete held, as the app's first boot does) its desktop is up, icon bar and all, on an A3000 and an A440/1 (23 emulated seconds) and an ARM3 A310 (15 s). The app's self-test, run where there are no development ROMs, switches on into ArcLibre's desktop.
- 4 MB ROMs (from Sophie's note: MEMC's high ROM is 8 MB at &3800000, and the sockets are wired for 4 MB ROMs, as in her "fifth column" hack putting an extension ROM after RISC OS 3.11; her Arculator PR does the same). MEMC already mirrored the image to a power of two, so a 4 MB ROM was all mapped (and mirrored once at &3C00000); the importer took only the size each version shipped as. Now an image may be bigger than that (4 MB at most), and four 1 MB chips or two 2 MB ones make one; more than MEMC's 8 MB is refused when loading.
- RISC OS 3.11 from 4 MB: when the second half isn't a mirror of the first, its self-test runs 31 s longer (a green screen) before RISC OS reads the keyboard, on an A3000, A440/1 or A540 alike, which is the 3.11 self-test bug Sophie mentions. With CMOS set up it then starts normally; the Delete held for a CMOS reset was let go too soon, so `Machine.powerOn` holds power-on keys 32 s longer for such a ROM. ArcLibre's self-test (3.60's) doesn't do it.
- Tests (`FourMegabyteROMTests`, `ROMImporterTests.testFourMegabyteROMs`): a 4 MB ROM's every part is mapped, and mirrored above &3C00000; RISC OS 3.11 and ArcLibre, each followed by 2 MB of other data, start the desktop from a CMOS reset; 4 MB images and chip sets are recognised in any order; half a ROM is still refused, and so is anything over 8 MB.

## Linux releases in Docker (2026-10-29)
- `scripts/release-linux.sh` builds LinuxArch's `.deb`s for amd64 and arm64 in Docker (`Apps/LinuxArch/docker/Dockerfile`: `swift:6.4.1-resolute` plus the GTK, libadwaita, SDL3, Wayland and GStreamer headers), from a copy in `build/linux-src` of the tracked files plus ArcLibre and the Level 4 disc; Swift's build folder stays in a volume per architecture. Each package is installed in a plain `ubuntu:26.04` container, checked with `ldd`, and `macarch-cli rom-info` reads its ArcLibre.
- On Apple silicon amd64 runs under Rosetta (Swift builds in about 100 s), but Ubuntu 26.04's GNU tar opens files with `openat2`, which Rosetta lacks ("Cannot open: Function not implemented"). So sources are copied on the Mac and mounted, and `make-linux-deb.sh` has `STAGE_ONLY=1` so a native container runs `dpkg-deb`.
- `scripts/release.sh` runs it first (`LINUX=0` skips it) into `build/releases/VERSION/linux`, and `--publish` attaches the debs to the same GitHub release, with LinuxArch's notes (from `Apps/LinuxArch/WHATSNEW.md`) after MacArch's. The two share a version: LinuxArch's first release is 0.4.0, and `release.sh` refuses a mismatch.
