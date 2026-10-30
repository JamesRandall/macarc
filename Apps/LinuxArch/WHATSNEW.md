# What's New in LinuxArch

<!--
LinuxArch's own release notes (MacArch's are WHATSNEW.md at the top): one
section per release, newest first, "## VERSION" (optionally "— DATE"), then a
line of introduction if wanted, then "- " bullets. Inline Markdown is fine.
The app shows the sections since the version a user last ran.
-->

## 0.5.3

- **Installers find a library:** new hard discs also get an empty Library directory, and a machine starts on its hard disc (drive 4) once one is fitted, as an owner would have set it with `*Configure Drive 4`. Installers that copy their tools into the library, such as Acorn C/C++'s, then work.

## 0.5.2 — 30 October 2026

- **!System and !Scrap on new hard discs:** a new hard disc, empty or made from files, has !System and !Scrap in its root directory, as on Acorn's own RISC OS 3.1 hard discs, so installers that add modules to `System:Modules` (Acorn C/C++'s, for example) and applications that pass files to each other work.
- **ArcLibre 0.9.1:** the free RISC OS that comes with LinuxArch is now [ArcLibre 0.9.1](https://github.com/acorn-playground/arclibre/releases/tag/v0.9.1), whose extras disc has !System and !Scrap as well.

## 0.5.1 — 30 October 2026

- Released alongside MacArch 0.5.1, which fixes a MacArch-only problem; LinuxArch is unchanged from 0.5.0.

## 0.5.0 — 30 October 2026

- **Floppy drive sounds:** the drive's motor spinning up and down and its head stepping and seeking, from MAME's recordings of a 3.5" drive, as in MacBeeb. On unless you turn them off with Machine ▸ Disc Drive Sounds.
- **ArcLibre 0.9:** the free RISC OS that comes with LinuxArch is now [ArcLibre 0.9](https://github.com/acorn-playground/arclibre), in both its forms, replacing 0.8. The **2 MB ROM** runs on every model, the A5000 family included; the **4 MB ROM** has DOSFS, Alarm and printing built in, and is for the A5000, A3010, A3020 and A4000, whose sockets take it. Both join the ROM list, named with their sizes.
- **ArcLibre's extras disc:** Disc ▸ Insert ArcLibre Extras Disc puts in the disc that goes with the 2 MB ROM, with DOSFS, !Alarm and !Printers. It's a copy kept in LinuxArch's own folder, so you can save changes to it.
- **ROMs that suit the model:** changing model swaps a ROM that can't drive it for one that can, keeping to ArcLibre if that's what you were using (or RISC OS 3 for 2).

## 0.4.0 — 29 October 2026

The first release: MacArch's Archimedes, as a GTK4 and libadwaita app.

- **Every model:** the 300 and 400 series, the A540, the A3000, and the A5000, A3010, A3020 and A4000, with their processors, memory and monitors, from the header bar's model button or **Configure Machine** (Ctrl+Shift+Alt+C).
- **ROMs:** drop a ROM image, chip files, a folder of them or a ZIP archive on a window, and LinuxArch works out what it is. ArcLibre, the free RISC OS, comes with builds that include it.
- **Floppies:** ADFS D, E, F, L, M and S, and protected JFD and HFE originals. The machine's writes stay in memory until you save them back, or as a new image; new blank discs too.
- **Hard discs:** ST506 and IDE drives, new and formatted, made from ZIP archives and folders of RISC OS files, resized, and with files added.
- **Rewind** the last minute, or pick a moment on the timeline; save states and quick saves.
- **The mouse:** captured with a click (held still on Wayland, so games read it properly; Ctrl+Shift+M lets it go), or free, with RISC OS's pointer following the desktop's.
- **The keyboard** by position (the Archimedes' layout) or by character (yours), with custom keys.
- **Display:** sharp pixels, smooth or CRT, with the full border, a little of it or none; zoom and fullscreen.
- **The Game Library** (Ctrl+Shift+Alt+G): the Archimedes Classics, a Top 25 whose discs you download from the Archimedes Archive in your browser (LinuxArch spots them in Downloads and adds them), and My Games, your own discs and covers. Play sets the machine up as the game wants it; a game on several discs gets the next when it asks.
- **The Network Studio** (Ctrl+Shift+Alt+0): Archimedes on an Econet, each running Acorn's own network software. Lay them out on the canvas, use them side by side in tiles or one large, watch every frame on the line, set up a Level 4 File Server, and follow the Distributed Mandelbrot demo. **Share a network over the Internet** with a link or a code, and others join it from LinuxArch, MacArch or MacBeeb.
- **The debugger** (Ctrl+Shift+D): disassembly with breakpoints, memory, registers, watchpoints, the hardware's state, a trace and a profiler; stepping back and reverse continue. Or debug a **BASIC** program by its lines, with its variables, calls, breakpoints and watches.
- **Disc Contents** (Ctrl+Shift+I): a floppy's or hard disc's files, dragged out and in, renamed, retyped, locked and deleted, with undo.
- **Video recording** (Ctrl+Shift+Alt+R): MP4 (H.264) or MOV (ProRes), with GStreamer, in the machine's own time.
- **AI agents:** `macarch-mcp --attach` drives the machine in the window as you watch (the main menu's AI Agents has the commands to add it to Claude Code or Codex, and an activity log), and VS Code's MacArch extension debugs over the Debug Adapter Protocol.
