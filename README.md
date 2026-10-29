# MacArch

A native macOS Acorn Archimedes emulator: the 300 and 400 series, the A540, the A3000, and the A5000, A3010, A3020 and A4000 (ARM2, ARM3 or ARM250; MEMC, IOC, VIDC; WD1772 or the 82C711's floppy controller; ST506 or IDE hard discs). The emulation core is written in Swift, the UI uses SwiftUI and Metal, and a headless CLI and MCP server share the same core.
Current status: RISC OS 3.11 and 2.00 boot to the desktop, and ADFS floppies can be browsed. See `docs/progress.md`.

## You need
macOS 26+ and Xcode 26+ (Swift 6.2 tools). MacArch comes with ArcLibre, a free RISC OS rebuilt from Acorn's public sources; for Acorn's own RISC OS 2 or 3, a ROM that you own: a single image, or a folder of chip files such as `IC24.ROM`…`IC27.ROM`. Put ROMs in `roms/`, which is git-ignored.

## Run the app
```sh
tests/scripts/build-app.sh && open build/MacArch.app
```

### On Linux
The same package builds **LinuxArch** on Linux: the same emulation, CLI and MCP server, with a GTK4 and libadwaita app (Ubuntu 26.04 or similar). `swift run linuxarch` runs it; `make install-user` installs it with its desktop entry, icon and file types; `make deb` and `make flatpak` package it. See `Apps/LinuxArch/README.md` for what it needs, how it maps to the Mac app, and how it differs.

MacArch can't include Acorn's RISC OS, but it comes with [ArcLibre](https://github.com/acorn-playground/ArcLibre), a free ROM for the earlier Archimedes restored from Acorn's publicly released RISC OS 3.60 sources (Apache License 2.0), aiming at RISC OS 3.11 compatibility. It's in the ROM list from the first launch, and it's the default until you add one of Acorn's, so a new window switches straight on into its desktop. It has drivers for the machines before the A5000 (it starts the desktop on the A3000, the A440/1 and an ARM3 A310), not the A5000 family, and Archimedes Classics still want Acorn's RISC OS. Take it off the ROM list and it stays off. `Apps/MacArch/Resources/ArcLibre` holds the ROM with its licences and provenance; `scripts/update-arclibre.sh` refreshes it from an ArcLibre build. The first window is a welcome screen: drop ROMs on it (a ROM image, the chip files of a set such as IC24–IC27, a folder of them, or a ZIP archive of any of these) or choose them, pick a model, and Switch On. MacArch works out what each file is: it finds the layout (one image, consecutive slices, or byte- or halfword-wide chips in any order), checks the reset vector, reads the version string (which only comes out readable in the right chip order) and the size that version shipped as (or bigger: the sockets are wired for 4 MB, so a 4 MB image, four 1 MB chips or two 2 MB ones holding RISC OS with more after it are taken too), and marks images whose SHA-256 is a known good dump. Files that aren't usable are listed with the reason (one chip of a set on its own, a part of a larger ROM, the wrong size). ROMs found are copied, as single images, into `~/Library/Application Support/MacArch/ROMs`, so the originals can be moved or deleted. Later, MacArch ▸ ROMs… (⌥⇧⌘R), Machine ▸ ROM ▸ Add ROMs… or Settings open the same drop zone and the ROM list; dropping ROMs on a running machine's window adds them too.

On first launch, choose a model and a ROM. The first boot of each model and ROM holds Delete to reset CMOS; after that, CMOS is saved per model and ROM in `~/Library/Application Support/MacArch/Profiles/`. The app's layout follows MacBeeb:
- **File:** Open Disc… ⌘O (also by dropping a file on the window or opening it from Finder), Open Recent, Save Disc Changes ⌃⌘S, Save Disc As…, Eject Disc ⌘E, New Disc (a blank ADFS E, D or L floppy), Show Disc Contents ⇧⌘I, Hard Disc (400 series and the A5000 family: New, New from Files, Show Contents, Add Files, Resize, Open and Remove for drives :4 and :5), Save Screenshot… ⌘S, Save State… ⇧⌘S, Load State… ⇧⌘L, Quick Save ⌥⌘S, Quick Load ⌥⌘L, Start/Stop Recording ⌥⌘R (MP4 is H.264; MOV is ProRes).
- **Edit:** Copy ⌘C and Paste ⌘V: in a text field, the usual editing; at a machine, Copy copies its screen and Paste types the clipboard into it. Copy Screenshot and Paste Text into Archimedes do just that from anywhere.
- **View:** Display (Sharp Pixels, Smooth or CRT), Border (Full, Small or None: how much of the border around the desktop shows), Zoom 50–200%, Actual Size ⌘0, Zoom In ⌘=, Zoom Out ⌘-, plus the standard toolbar and full-screen items.
- **Debug:** Show Debugger ⌥⌘D, Break into Debugger / Continue ⌃⌘Y. The debugger window has disassembly with symbol labels and profile heat bars (click a line's gutter to toggle a breakpoint), memory (logical, physical or ROM; changes since the last stop highlighted, double-click a byte to edit it), and a sidebar of CPU (registers, banked sets, flags, stack), Breakpoints, Hardware (IOC, MEMC, VIDC, sound, floppy, IDE/ST506, keyboard, CMOS), Trace, Profile and Log. Its toolbar: Continue/Pause ⌃⌘Y, Step Over F6, Step Into F7, Step Out F8, Step Back ⇧F7, Reverse Continue ⇧⌃⌘Y, and Step By (next scanline, frame or interrupt). Breakpoints can be on execute, read, write or any access, over an address range, with a condition, a hit count, a processor mode or a log message instead of stopping. Conditions and addresses are expressions: `&`/`$`/`0x` hex, `%` binary, registers (R0–R15, SP, LR, PC, PSR, MODE, N Z C V I F), `[addr]` for a byte, `{addr}` for a word, symbols, and C-style operators. Step back and reverse continue replay the rewind history (the last minute). While the debugger is open, hovering over the display shows the video memory address under the pointer. The toolbar switches between Machine Code and BASIC (a BASIC stop switches it): see Debugging BBC BASIC.
- **MCP:** Connect an AI Agent… (the commands that add this copy of MacArch to Claude Code or Codex), Activity Log ⌥⌘L (every tool call, its arguments, result and screenshots). A toolbar light shows when an agent is attached.
- **Machine:** Pause ⌘P, Full Speed ⌥⌘F, Mute ⌥⌘M, Reset ⌘B, Power Cycle ⇧⌘R, Mouse (Capture the mouse, or Follow the Mac pointer), Capture or Release Mouse ⌃⌘M, Rewind 5 Seconds ⌥⌘←, Rewind Timeline… ⇧⌥⌘←, Configure Machine… ⌥⌘C, then the Model, Processor, Memory, Monitor and ROM pickers (as in MacBeeb, a change power cycles; the floppy stays in, and each model remembers its own processor, memory, monitor and hard discs).
- **Configure Machine** (⌥⌘C, or click the toolbar's model button): the model, processor, memory, monitor, ROM and hard discs in one window. Each choice is a card describing it, and the one in use is marked Fitted. Changes wait until Restart Machine, as each power cycles; hard disc actions apply straight away.
- **Toolbar** (customisable): model, disc, hard disc, reset, power, rewind, pause, full speed, screenshot, record, state, and the Caps/Num/Scroll and disc lights. Mute, display and keyboard items are available through View ▸ Customize Toolbar.
- **Settings** (⌘,): the ROM list and the model, processor, memory and monitor new windows start with, the mouse mode and buttons, the keyboard mode (Archimedes layout by position, or Mac layout by character), custom key mappings, and Debugging (the port VS Code connects to).

Click the display to capture the mouse; ⌃⌘M releases it, and so does switching away. Or choose Machine ▸ Mouse ▸ Follow the Mac pointer (also in Settings ▸ Mouse): the Mac's pointer then stays free, and RISC OS's goes wherever it is. The Archimedes mouse only reports movement, so MacArch steers: each frame it sees where the hardware pointer is and sends the counts to close the gap, learning how far a count moves it in each mode. It steers only for a moment after the Mac's pointer moves, so programs can still move the pointer themselves. Where a program turns RISC OS's pointer off and reads the mouse itself, as many games do, the Mac's movements are passed on instead, and capturing may suit it better. The Archimedes mouse has three buttons:
- **Select:** click.
- **Menu (middle):** ⌘-click (best on a trackpad, because Command is never passed to the guest), ⌃-click, or a real middle button.
- **Adjust:** secondary click (right or two-finger).

Settings ▸ Mouse can make the secondary click Menu instead; ⌥-click then gives Adjust.
Floppy images can be ADF (ADFS D/E 800K, including images a track or two short, as some imagers make; L, M and S), and for protected originals JFD or HFE (the HxC Floppy Emulator's raw track format, version 1, MFM: its tracks are decoded to their real ID fields, so odd sector numbering, missing sectors and CRC errors survive). The guest's writes go to an in-memory overlay, and the window title shows "(edited)". File ▸ Save Disc Changes (⌃⌘S) writes them back to the ADF, and Save Disc As… writes a new copy that the machine then uses. Before you eject, insert another disc, load a state or quit with unsaved changes, MacArch asks whether to save them. JFD and HFE images stay read-only (flattening them would lose their protection); keep their changes in a save state. The CLI and MCP server never write images back.
## Machines
| Model | Processor | Memory | Hard disc |
| --- | --- | --- | --- |
| Archimedes 305, 310 | ARM2 8 MHz (ARM3 card optional) | 512 KB – 4 MB | – |
| A3000 | ARM2 8 MHz (ARM3 card optional) | 512 KB – 4 MB | – |
| Archimedes 410/1, 420/1, 440/1 | ARM2 8 MHz (ARM3 card optional) | 1 – 4 MB | ST506 (HD63463), drives :4 and :5 |
| Archimedes 540 | ARM3 | 4, 8 or 16 MB (slave MEMCs), 12 MHz memory | – |
| A5000 | ARM3 | 1 – 4 MB, 12 MHz memory | IDE, drives :4 and :5 |
| A3010 | ARM250 (12 MHz) | 1 – 4 MB | – |
| A3020, A4000 | ARM250 (12 MHz) | 2 – 4 MB | IDE, drives :4 and :5 |

The A5000 family has the "new I/O": an 82C711 (a 765-style floppy controller, IDE, printer and serial ports) and the IOEB in place of the WD1772 and the I/O backplane. These machines need RISC OS 3: RISC OS 2.00 starts on them but its ADFS predates the 82C711, so it cannot use the floppy or IDE drives.

Monitor: a standard 15 kHz monitor, a multisync or a VGA. The A5000 family reads the monitor's ID lines, so after a CMOS reset RISC OS 3.1 picks a mode to suit (a 640 x 480 desktop on multisync and VGA); games written for those machines, such as Sim City 2000, need multisync or VGA. Older machines can't tell, so their Monitor menu offers only Standard; to use a multisync with them, `*Configure MonitorType 1` and a multisync `*Configure Mode` as on the real machine.

The ARM3 runs at 24 MHz (the emulator's master clock; real parts ran at 25–26 MHz) with its 4 KB cache modelled for timing; RISC OS turns the cache on itself (`*Cache` reports it). Expect BASIC to run about 4.5 times faster than on an ARM2. Processor also offers ARM3 ×2 and ×4, which are faster than any real ARM3, for games that wanted a RiscPC. Only the processor speeds up. Memory, video, sound and the timers keep their real speeds, so games keep real time, unlike Full Speed. The gain is less than the clock ratio because writes and cache misses still wait for memory: Doom's demo goes from about 4 frames a second to 6 at ×2 and 9 at ×4.

Hard discs are raw image files (`.hdf`): 256-byte sectors for ST506, 512-byte for IDE. File ▸ Hard Disc ▸ New Hard Disc… makes one already formatted (old map, as `!HForm`'s old-map option does: 20, 40 or 64 MB ST506; 40, 120, 250 or 500 MB IDE), so RISC OS can use it straight away; no Apps disc is needed. New Hard Disc from Files… makes one holding the files from ZIP archives, folders or ADFS floppy images (D or E format; ADF, JFD or HFE): software that came as files rather than discs (Sim City 2000's A5000 version, say), or a floppy's contents. Add Files to Hard Disc… copies more onto a fitted drive alongside what is already there. It makes any directories that are missing and replaces files of the same name, after showing which ones. Then it restarts the machine, since RISC OS keeps the drive's map and directories in memory. It works on old-map drives (the ones MacArch makes, and !HForm's old-map option). If there's room in all but not in one piece (files must be contiguous on an old-map drive), MacArch offers to compact the drive first, as `*Compact` does. Dropping ZIPs or folders that aren't ROMs on a running window offers both choices. ST506 drives (the 300 and 400 series and the A540) and IDE drives (the A5000 family) have different sector sizes, so a drive of one kind can't be fitted in the other. Opening one offers to copy its files, directories and disc name onto a new drive of the right kind, saved beside it; the original is left alone. Resize Hard Disc… picks a new size from the same list as New Hard Disc, keeping the drive's files where they are (it restarts the machine). Growing adds free space at the end. Shrinking needs the files to fit below the new end, and offers to compact the drive first if that would make them fit. Stored, deflated and imploded (PKZIP 1) members are read. Filetypes and dates come from the archive's RISC OS information (the Acorn extra field SparkFS and other RISC OS zip tools write), or from a `,xxx` suffix on a name (`!Run,feb`); otherwise `!Run` and `!Boot` are Obey files and the rest Data. A `.` in a Mac name becomes `/`. Names must fit ADFS (ten characters) and each directory holds up to 77 entries; MacArch says which name or directory doesn't fit. The drive count in CMOS (`*Configure HardDiscs` or `*Configure IDEDiscs`) is set for you when a drive is fitted, including after a CMOS reset. Writes go straight to the image file, as on a real drive. Save states and rewind record which hard disc is fitted but not its contents; rewinding past hard disc writes asks first, because RISC OS would find its files changed underneath it.

### Disc contents

File ▸ Show Disc Contents (⇧⌘I) lists the files on the floppy in drive :0 and on the hard discs fitted (the window's toolbar picks the drive), as MacBeeb's does for BBC discs. It reads ADFS L, M, S, D, E and F floppies and old- and new-map hard discs, with their directories (double-click one to open it). Drag files out to Finder, or Export…, and each is named with its RISC OS type (`ReadMe,fff`, or `Code,00008000-0000801c` for load and execution addresses), so it comes back in as it went. Drag Mac files and folders in (onto a directory's row to go into it), or Add Files…: a `,xxx` suffix gives the type, as does a `.inf` file beside it (MacBeeb's and other emulators'), a known extension (`.txt` is Text, `.png` PNG and so on; it's dropped), or the usual names (`!Run` is Obey); a `.bas` file of text becomes a tokenised BASIC program, and folders become directories (a folder called `!Something` is an application). Names lose what RISC OS can't hold (`.` becomes `/`, spaces hard spaces) and are cut to ten characters; on L, M and S discs, whose old directories keep only R, W, L and D access and plain ASCII names, anything else becomes `_`. Get Info renames a file, retypes and redates it (or sets its load and execution addresses), and sets its access; New Directory makes one; Delete deletes files and directories with everything in them; the header sets the disc's name and boot option. Everything can be undone. A floppy change waits until the drive has been still for a couple of seconds, then goes into the disc in the drive with a new disc ID and the disc-changed signal, so RISC OS reads the disc afresh; like RISC OS's own writes it stays in memory until File ▸ Save Disc Changes. A hard disc change is written to its file, with the machine's writes held off, and the machine then restarts, as RISC OS keeps a hard disc's map in memory. With the floppy drive empty, the window offers New Disc (a blank E format disc for RISC OS 3, D for RISC OS 2, or L for Arthur and the BBC Master) and Insert Disc. Copy protected discs (JFD and HFE images, and ADFs short of their last tracks) are shown too: files on the odd sectors can't be copied (a folder's other files still are, and you're told which were left out), and new files keep clear of every track with anything odd on it, even where the disc's map calls it free, so the protection isn't touched. Many protected games mark their protection tracks free, so their discs show as full until something is deleted. Holed Out still plays after its disc is changed. Discs with big directories (E+ and F+, from RISC OS 4) aren't supported.

## Welcome screen

MacArch opens with a welcome screen, as MacBeeb does: its three parts (an Archimedes, the Game Library and the Network Studio), with ways into each (switch on, browse or add games, join a network with a code, open a recent one, make a new one), and things to try (the Distributed Mandelbrot, a school classroom with its Level 4 server, connecting an AI agent, what's new). Choose what MacArch opens with at its foot, or in Settings ▸ General: the welcome screen, an Archimedes, the Game Library or the Network Studio. With the welcome screen, closing the last window brings it back, and closing it quits. Window ▸ Welcome to MacArch (⇧⌘1) shows it any time.

## Game Library

Window ▸ Game Library (⇧⌘G) has two shelves, as MacBeeb's does: the Archimedes Classics and My Games.

**Archimedes Classics** is a Top 25 of Archimedes games, from Star Fighter 3000 to Repton 4, with their box art and a book at the end for the [Archimedes Archive](https://arcarc.top/) their discs come from. MacArch never downloads or includes the discs: Get opens the game's folder in the archive in your browser (each disc also has its own link in the game's details), and MacArch, with your permission, watches Downloads for them (Settings ▸ General ▸ Game Library), recognising each by its SHA-256 and copying it into Application Support/MacArch/Library/Classics. Dropping the discs on the library, or Add Discs…, does the same. The catalogue is `Apps/MacArch/Resources/Classics/classics.json`: each game's discs (the archive's file, its digest and its ADFS name), the machine it plays on, and how it starts. Play makes the Archimedes in front that machine (an A3000 with RISC OS 3, say; Lemmings is an A5000 with its archive as an IDE hard disc), from a CMOS reset and without changing the machine in Settings, waits for the desktop, and starts the game as the Filer would (`Filer_Run`, by disc name for games on several discs; `*Run` on RISC OS 2). Games that wait on the icon bar (Elite, SimCity, Dune II) have their icon clicked. When a game asks for another disc in text ("Please insert Disk Two"), it goes in by itself; otherwise Machine ▸ Insert Disc 2 (⌥⌘N), or the toolbar's disc button, puts the next one in. Changing the machine by hand ends the game and brings back yours. `MACARCH_CLASSICS_DISCS=top25 swift test -c release -Xswiftc -enable-testing --filter ClassicsDiscTests` (in Packages/ArchimedesCore) boots each one from a folder of the discs, with screenshots in tests/reports/classics.

**My Games** is a shelf of your own Archimedes games. Drag in floppy images (ADFS, JFD, HFE) and cover pictures, in either order or together: a disc and a picture with the same name make one game. Each game keeps its own copy of its disc (in Application Support/MacArch/Library/MyGames; the original's never touched), the machine it plays on (model, memory and RISC OS 2 or 3, matched against your ROMs), and how it starts: an application on the disc (suggested when the disc has one, so Lemmings starts `!Lemmings`), the disc's `!Boot`, a command typed at the command line (`DIR ADFS::0.$;!RISC_OS` for Repton 3), or just put in. Double-click a game, or Play in its details, and it starts in the Archimedes in front (or a new one), changing that machine to the one the game wants.

## Networks (Econet)

File ▸ New Network… (⇧⌘N) builds a network of Archimedes on an emulated Econet, each running for real, with Acorn's own network software from the ROM (RISC OS 2 and 3 have Econet, NetFS and NetPrint built in). Start from a template (Two Archimedes, School Classroom, The Archimedes Family, Distributed Mandelbrot, or an empty network), then add machines from the palette. Window ▸ Network Studio (⌥⌘0) brings it back. The studio is MacBeeb's: a canvas of cards with the machines' screens live and the cable they share drawn behind them (a machine sending glows green); Tiles, with the machines side by side (click one to type into it and hear it; ⌥⌘[ and ⌥⌘] move the keyboard); Focus, with one large and every machine that's on in a strip down the left (click one to bring it into the large view); and Traffic, with every frame on the line read as Econet's four-way handshake (scout, acknowledgement, data, acknowledgement), exportable as JSON in MacBeeb's format. The inspector sets each machine's name, station number, model, processor, memory and ROM, and its floppy and hard discs; double-click a card (or Open Window) for the machine's own window, with all its menus. Pause Network stops time everywhere, so nothing times out; a breakpoint in one machine's debugger pauses the rest too (an option).

Each machine has Acorn's Econet module (an MC68B54 at &33A0000, interrupting on FIQ), and its station number goes in CMOS byte 0, as `SetStation` would put it. The A3010 has no Econet header, so it can't join. Networks are packages (`.macarchnet`) in Documents ▸ MacArch Networks, saved as you work: the network keeps its own copies of its discs (a hard disc copy is an APFS clone, so it costs nothing until written) and each machine's CMOS. What's in the machines' memory isn't saved. A file server is an A440/1 on station 254 running Acorn's Level 4 File Server, which MacArch includes (Release 3): the templates' servers come set up, and a machine's inspector's Set Up Level 4 (or the card's menu) makes one a server. MacArch copies !Server, !System and the other applications onto a new hard disc with a boot file that starts the server, picks a RISC OS 3 ROM (Release 3 needs 3.10 or later), and keeps the CMOS settings it needs (boot from ADFS drive 4, 1024K of RMA). The other machines then log on with `*I AM SYST` at the command line, or from the desktop's Econet icon. A machine's inspector also sets what it starts up with: its own discs, NetFS, or booting from the network (NetFS logs on as BOOT at power-on and runs the server's `$.BOOT.!ArmBoot`). See `docs/econet-notes.md`.

**Over the Internet**: the studio's globe button (or File ▸ Share Network Over Internet…) puts a network in a private room on an Internet Econet service (econet.acornplayground.org by default; Settings ▸ Networking for another), with an invitation link or a join code (`ACRN-…`); File ▸ Join Econet Network… (⇧⌘J), or the link, joins one. Each Mac's machines appear on the others' canvases as dashed teal cards, and talk with RISC OS's own network software: a gateway on each line holds it while a frame crosses, so every acknowledgement comes from its real destination. MacBeeb uses the same rooms, so BBC Micros and Archimedes share a network: a BBC logs on to an Archimedes' Level 4 server, and an Archimedes to a BBC's Level 2 server. The host can let people show their machines' screens on everyone's canvas. Only Econet (and screens, if chosen) is shared.

The Distributed Mandelbrot template is MacBeeb's demo for the Archimedes: it comes ready: the file server has Level 4 and the demo's programs, the four A3000 workers boot from it into `Worker` and wait, and the Guide (an A5000) boots from its own disc and logs on as GUEST. On the Guide, `Mandel` finds the workers over Econet and hands out 300 tiles, which they compute in their own ARMs and send back. The studio's Mandelbrot view builds the picture from the frames on the line alone, and Traffic reads each of the demo's messages. See `Examples/distributed-mandelbrot`.

The machines run in lockstep, 16 µs of emulated time at a go; when one processor core can't keep a network at real time (or it's running flat out), they're spread over more cores, as long as each extra thread helps. Runs are the same whatever the thread count. `MACARCH_NETWORK_THREADS=N` fixes the count.

A state file references its disc images by path and SHA-256 and embeds only the disc's unsaved changes, so keep the images where they were. After a state is loaded, CMOS is no longer saved to your profile until the next power cycle. Rewind keeps the last minute (a point every half second; keyboard and mouse input in between is recorded and replayed exactly).
Opt-in automation hooks: `MACARCH_LOAD_STATE=file` resumes a state at launch; `MACARCH_DAP_PORT=N` serves the debug adapter on that port (self-tests serve it only then); `MACARCH_SELFTEST=out.png` boots, writes the menu structure, the window and the display, then quits; `MACARCH_SELFTEST_OPEN="Connect an AI Agent…,Activity Log"` also opens those menu items and captures every window; `MACARCH_SELFTEST_NETWORK=twoArchimedes` (or another template) makes that network, opens its studio (`MACARCH_SELFTEST_NETWORK_MODE=tiles` and so on), and writes a capture and a report of each machine's screen and the frames on the line (`MACARCH_SELFTEST_NETWORK_SEND=1` has station 1 send station 2 a message first; `MACARCH_SELFTEST_LEVEL4=<disc>` sets the file server up from that Level 4 disc, and station 1 logs on and catalogues it; `MACARCH_SELFTEST_NETWORK_FAST=1` runs the network flat out, to measure it).

## Packaging
```sh
tests/scripts/build-app.sh                 # build/MacArch.app (ad hoc signed; includes macarch-mcp and macarch-cli)
NOTARISE=0 scripts/release.sh 0.1.0        # universal DMG and zip in build/releases/0.1.0, not notarised
scripts/release.sh 0.1.0                   # Developer ID signed, notarised and stapled, plus appcast.xml
scripts/release.sh 0.1.0 --publish         # ...then tag v0.1.0 and make the GitHub release
```
Before a release, add a `## 0.1.0` section to `WHATSNEW.md` (newest first: an optional line of introduction, then `- ` bullets with inline Markdown). The release script won't build without it. It uses the section as the GitHub release notes and embeds it in the appcast, so it appears in Sparkle's update window. The app bundles the whole file. On the first launch after an update, it opens What's New with the releases since the version the user last ran marked New; Help ▸ What's New in MacArch opens it any time. A fresh install shows the welcome screen instead.
A notarised release needs APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID and CSC_NAME in the environment, in `.env.local` (git-ignored) or in the file named by `MACARCH_ENV_FILE`. The icon is an Icon Composer document whose layers are drawn by `Tools/icon/draw.py`. ArcLibre is the only ROM bundled.

Updates come through Sparkle, as in MacBeeb: MacArch ▸ Check for Updates…, plus automatic checks, against `https://github.com/JamesRandall/macarc/releases/latest/download/appcast.xml`. The release script adds the public EdDSA key to the app and signs the zip in the appcast, keeping earlier releases listed. The key is in the login keychain under the account `macarch`; create it once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account macarch`, and keep a backup (`-x FILE` exports it): losing it means existing installs can't verify new updates. Builds without the key, including local and unnotarised ones, don't check. The About box links to the repository and jamesdrandall.com.

## Tests and headless runs
Release test builds need `-Xswiftc -enable-testing`: SwiftPM's newer build system (Xcode 27) leaves it out, and a clean build then fails with "unable to resolve Swift module dependency".
```sh
(cd Packages/ArchimedesCore && swift test)        # no ROM needed; the ROM smoke test is skipped if roms/riscos3_11 is absent
swift test -c release -Xswiftc -enable-testing     # the debug adapter (needs roms/riscos3_11 for the end-to-end test)
node vscode-macarch/test/smoke.js 3200 "$PWD/Examples/hello-arm/hello.s" 19   # against the running app, from a clone of the extension
(cd Packages/ArchimedesCore && MACARCH_GAME_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter GameSmokeTests)   # the four games; reports in tests/reports/games
(cd Packages/ArchimedesCore && MACARCH_GAME_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter CollectionSmokeTests)   # the wider collection
swift build -c release
.build/release/macarch-cli run --rom roms/riscos3_11 --cmos-reset --seconds 25 --screenshot out.png --diagnostics
.build/release/macarch-cli disk-inspect discimages/adfs_Repton_3.adf
```
`run` also accepts `--model A440/1` (or A305, A310, A3000, A410/1, A420/1, A540, A5000, A3010, A3020, A4000), `--cpu ARM3`, `--ram-kb N`, `--hard-disc FILE.hdf` (repeatable), `--reset-at S`, `--disc`, `--write-protect`, `--type TEXT --type-at S`, `--key NAME@S`, `--mouse DX,DY@S`, `--click select@S`, `--break EXPR` (a debugger expression), `--registers`, `--trace-tail N`, `--screen-text`, `--watch-logical HEX,LEN`, `--cmos FILE`, `--save-cmos FILE`, `--text`, `--wav FILE`, `--swi-log HEX,…`, `--vidc-log N`, `--floppy-trace`, `--dump START,LEN,FILE` and `--disasm ADDR,COUNT`.
`macarch-cli assemble FILE.s [-o OUT.bin] [--symbols OUT.sym] [--list]` assembles ARM code (see below); errors go to stderr as `file:line: message`.
`macarch-cli hard-disc-create FILE [CYLINDERS HEADS [SECTORS]] [--ide] [--blank]` makes a formatted image: ST506 by default (615 × 4, 20 MB), or IDE with `--ide` (977 × 5 × 17, 40 MB). `--from ARCHIVE.zip` (or a folder, or a floppy image) puts those files on it, as New Hard Disc from Files does. `macarch-cli disk-files IMAGE [--extract FOLDER]` lists an ADFS D or E floppy's files (and copies them out, with `,xxx` type suffixes). `macarch-cli hard-disc-add FILE SOURCE...` adds ZIPs, folders or floppy images to an existing drive, as Add Files to Hard Disc does, and prints what was added and replaced; `--compact` compacts the drive first. `macarch-cli hard-disc-resize FILE CYLINDERS HEADS [SECTORS] [--compact]` resizes one, keeping its sector size. `macarch-cli hard-disc-copy SOURCE DESTINATION [CYLINDERS HEADS [SECTORS]] [--ide]` copies a drive's contents onto a new one of either kind.
`--save-snapshot FILE` writes the state at the end of the run. `--load-snapshot FILE` resumes from a snapshot instead of powering on; `@S` times then count from the snapshot point. `macarch-cli snapshot-info FILE` prints a snapshot's header.
Runs are deterministic: the same inputs give the same frame checksum. A run resumed from a snapshot matches an uninterrupted run exactly.

## MCP server
`macarch-mcp` speaks MCP (JSON-RPC 2.0, newline-delimited) over stdio, after MacBeeb's. The easiest way to set it up is MCP ▸ Connect an AI Agent… in the app, which gives the command for this copy of MacArch:
```sh
claude mcp add macarch -- '/Applications/MacArch.app/Contents/MacOS/macarch-mcp' --attach
```
Codex (`~/.codex/config.toml`):
```toml
[mcp_servers.macarch]
command = "/Applications/MacArch.app/Contents/MacOS/macarch-mcp"
args = ["--attach"]
```
With `--attach` the agent drives the machine in the running app's first window (or a network's machine: see below), over a user-only socket at `~/Library/Application Support/MacArch/agent.sock` (or `MACARCH_AGENT_SOCKET`), so you watch what it does. Between tool calls the machine runs in real time, so you can watch and join in; tools that run it advance it faster than real time, after which the window catches up. `set_real_time` with `on: false` holds it still between calls, for exact experiments: the window title then shows "(Held by AI Agent)", and Resume or the agent disconnecting lets it go. Files are limited to Application Support, Desktop, Documents, Downloads and the folders of your ROMs and recent discs, unless `MACARCH_ALLOWED_DIRS` is set for the app.

Without `--attach`, the server runs a hidden Archimedes of its own (`--model A5000` and so on), booted to the desktop with a fresh CMOS. Its ROM comes from `--rom PATH`, `MACARCH_ROM` or the ROM chosen in the app. File access is limited to `MACARCH_ALLOWED_DIRS` (colon-separated); the default is the current directory plus Application Support. This repo's `.mcp.json` has both entries, using `.build/release/macarch-mcp`.

Tools:
- **Machine:** get_status, set_real_time, power_cycle (optionally to another model, processor, memory, monitor, ROM or hard discs, or with a CMOS reset), press_reset, load_disc, eject_disc, save_snapshot, restore_snapshot, save_state, load_state, start_recording, stop_recording (app only).
- **Input and screen:** run_command (types a command at the `*` prompt or BASIC, pressing F12 first from the desktop, and returns the new screen text), type_text, press_keys, mouse (relative or absolute moves, buttons, clicks), screenshot, read_screen_text (the system-font text on the screen).
- **Running:** run, run_until_idle (until RISC OS waits for input), run_until_address.
- **Debugging:** registers, set_register, peek, poke, disassemble, memory_regions, set_breakpoint (also on a source line, `hello.s:19`), list_breakpoints, delete_breakpoint, continue, step (into, over, out, back, scanline, frame, interrupt), reverse_continue, rewind, trace, load_symbols, lookup_symbol, profile, debug_log.
- **Programs:** assemble (assembles an ARM source file, loads it with its labels and source lines, and runs it from the `*` prompt).
- **BBC BASIC:** basic_load (a program from a file or text, loaded at BASIC's prompt and RUN), basic_set_breakpoint (on a line or statement, with a condition, hit count or log message), basic_list_breakpoints, basic_delete_breakpoint, basic_stop_on_errors, basic_step (into, over, out), basic_where (the line, error, PROC/FN calls and LOCALs), basic_list, basic_variables, basic_evaluate, basic_set_variable.
- **Networks (app only):** every tool takes `machine` (a Network Studio machine's name, station number or id; "Network/name" picks the network) to drive that machine; a tool that runs it runs its whole network in step. list_machines, network_status, network_power (on, off, power_cycle, reset, suspend, resume), network_pause, network_trace (the frames on the cable, with `after` for polling), network_create (from a template), network_open, network_set_up_level4. econet_status shows a machine's network chip (headless too). The socket also starts when a network opens, so agents can drive networks with no machine window open.

## Writing and debugging ARM code
MacArch has its own ARM assembler (ARM2, ARM3 and ARM250). It takes BBC BASIC V's assembler syntax as a file of its own:
```
        ORG     &8000               ; where it loads (the default)
.start  SWI     OS_GetEnv           ; labels: .name, name:, or a name in column 1
        MOV     R13, R1
        ADR     R0, greeting
        SWI     "OS_Write0"         ; SWIs by name (in quotes or not) or number
        SWI     OS_Exit
.greeting
        EQUS    "Hello!"
        EQUB    0
        ALIGN
```
- **Instructions:** all of the ARM2's, with conditions before or after the suffixes (`ADDEQS` or `ADDSEQ`), plus SWP, the coprocessor instructions, ADR, ADRL and NOP. `LDR R0, =value` uses a literal pool, and `LDR R0, label` is PC-relative. An immediate that doesn't fit is turned round where it can be (`MOV R0, #-1` becomes `MVN R0, #0`).
- **Directives:** ORG, ENTRY, ALIGN, EQUB/EQUW/EQUD/EQUS (or DCB/DCW/DCD/DCS), SKIP, LTORG, INCLUDE, INCBIN, END, and constants as `name EQU value`, `name * value` or `name = value`.
- **Expressions and comments:** expressions are the debugger's, with `.` for the current address. Comments start with `;`, `\` or `//`.

Programs are loaded at their ORG from the `*` prompt (F12 from the desktop), started with `*Go`, and end with `SWI OS_Exit`.

To assemble and run a program, use the **VS Code extension** ([its own repository](https://github.com/acorn-playground/vscode-macarch); see its README to install it), the MCP `assemble` tool, or `macarch-cli assemble`.

With the extension, press F5 in a `.s` file. While MacArch is running, it serves the Debug Adapter Protocol on localhost port 3200 (Settings ▸ Debugging; `MACARCH_DAP_PORT` overrides it). The extension provides:
- breakpoints in the source, with conditions, hit counts and log points;
- step over, into, out of and back, and reverse continue;
- editable registers and flags, and the banked registers;
- memory, disassembly and watchpoints;
- the hardware state;
- the program's output in the debug console.

See `Examples/hello-arm`.

## Debugging BBC BASIC
The debugger window's BASIC view (choose BASIC in its toolbar) debugs a BBC BASIC V program by its lines, as MacBeeb's does. It works with the BASIC in RISC OS 2 and 3's ROMs, found by its code.
- **The listing**, with a breakpoint gutter (click a line; Control-click for a statement, a condition in BASIC such as `I%>10`, a hit count or a log message like `I%={I%}`). The line and statement it's stopped at are marked, and an error shows where it happened.
- **Variables:** LOCALs and parameters of the PROC or FN it's stopped in first, then the others, arrays (open one for its elements) and @% to Z%. Double-click one to set it to a BASIC expression.
- **Calls** (the PROCs and FNs being run), **Breakpoints** (with stop on errors: off, those no ON ERROR handles, or all), **Watch** (BASIC expressions) and the **Log**.
- **Stepping** by statement: Step Over F6 (running PROCs, FNs and GOSUBs through), Step Into F7, Step Out F8; Pause ⌃⌘Y stops at the next statement.

A `.bas` file dropped on the machine's window, or opened with MacArch, is tokenised (it can be text, with or without line numbers, or tokenised as SAVE writes it), loaded at PAGE and RUN, if BASIC is at its prompt (press F12 and type `BASIC`).

In VS Code, press F5 in a `.bas` file (or launch with `"basic": "program.bas"`): MacArch goes to BASIC's prompt, loads the program and RUNs it, with breakpoints on its lines, steps by statement, the PROC and FN calls as the call stack, BASIC's variables (to set too), BASIC expressions in the console and hovers, and BASIC errors as exception breakpoints. See `Examples/hello-basic`.

## Browser (WebAssembly)

The same `ArchimedesCore` also builds for WebAssembly and runs in a web page
(a Web Worker, canvas, sound, keyboard and pointer-locked mouse):

```sh
scripts/build-wasm.sh                                  # needs the swift.org 6.4.1 toolchain + WASM SDK
scripts/bundle-web.sh <rom> zarch <Zarch.adf>          # optional: bundle a ROM and a Classic, locally
node web/serve.mjs                                     # http://localhost:8080/
```

See [docs/wasm.md](docs/wasm.md) for the design, ABI, tests and measurements.

## Licensing
MacArch is free software under the GNU General Public License, version 3 (see `LICENSE`). The Swift code is original. See `docs/reference-audit.md` for how the reference emulators were used. ROMs and disc images are not distributed.

### Import and export a machine configuration

The welcome screen’s **Import Machine…** button (above Add ROMs…) imports and starts a new machine. **Machine ▸ Import Machine Configuration…** is also available from the welcome screen; with a machine window focused it imports into that machine. Cancel or a failed import leaves the welcome screen and existing sessions unchanged.

Machine ▸ Import Machine Configuration… opens a `MachineConfiguration` JSON file, including ArcLibre's `arclibre.machine.json`. Relative ROM, hard-disc and CMOS paths are resolved beside that JSON. Unsupported settings and missing files are reported before replacing the running machine. Import asks before restarting, copies the ROM into the ROM library and uses a private copy of CMOS, so the original CMOS file is not changed. Imported boot settings stay with this window through resets and hardware changes; reopen the JSON to restore them in a later app session.

Machine ▸ Export Machine Configuration… saves the current hardware/boot configuration plus a uniquely named `.cmos` companion containing current CMOS. Keep both files together. ROMs and hard discs are referenced, not included; paths beside the JSON become relative. The Configure Machine window also has a Configuration menu. Exports describe the running machine, not unapplied setup edits. Use Save State for running programs, RAM and inserted floppy contents. Network stations use their network's configuration instead.
