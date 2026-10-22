# Compatibility

Local machine (games): A3000, ARM2, 2 MB. ROMs: RISC OS 3.11 (29 Sep 1992), sha256 `e916a0b8…7384`; RISC OS 2.00 (05 Oct 1988), sha256 `b2658bb1…68d3`.
The full local manifest (hashes, formats) is `tests/reports/disc-manifest.local.json`, generated with `macarch-cli manifest discimages`.

| Title | image SHA-256 (prefix) | format | ROM | boots | launches | input | video | sound | 10-min play | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Repton 3 | db647c50a05616c1 | ADFS D 800K | 3.11 | n/a | **yes** | yes (keys) | title, menu and level correct | not checked | not tested (user played it in the app) | Recipe: F12, `DIR ADFS::0.$`, `!RISC_OS`, then 1 (the game) and Space. X walks right. |
| Lemmings | 13e86e6dcd4a18bf | ADFS D 800K | 3.11 | n/a | **yes** | yes (mouse) | level and panel correct, including the timer-driven panel palette split | not checked | not tested | Recipe: open `:0`, double-click `!Lemmings`, single-click START (the pointer is the hand; its hotspot is the fingertip), click again on the level preview. Needed raster lines not to be stretched by video DMA (palette split was about 17 lines early). |
| Holed Out!! | 2fbff6ded71ed5c9 | gzip JFD (multi-member), ADFS D layout plus protection: t14s1 sector 4 missing, t15–16 and t17s0 unformatted, t17s1 sector 4 only, t57+ partial/unformatted | 3.11 | **yes** (`!BOOT` from `*` prompt) | **yes** | yes (mouse) | title, menus and hole 1 correct | not checked | not tested | Recipe: F12, `/adfs::0.$.!BOOT`. Menus: NO (instructions), click past the title, CONE LINKS, PLAY, STROKE PLAY, 1 player, name, LEFT, BEGINNER, YES, then hole 1 with the club list. Shots work. The Archimedes version is mouse-driven (see its in-game instructions; the printed manual describes keys): button 1 (Select) picks another club; button 2 (the middle button, Menu) accepts the aim, starts the power bar, and pressing it again plays the shot. Button 3 (Adjust) also picks another club. The scripted test plays a 1 Wood from the first tee (strokes 1, 361 yards to go). The first run saves a CMOS backup (`Cram`) into t14s1 sector 4 and reboots; the disc must be writable (with write-protect on, the game asks you to remove it). |
| Elite (on Acorn User Aug 95 disc, `$.!AUélite.élite.!élite`) | b6853ba6bb39b634 | ADFS E 800K | 3.11 | n/a | **yes** | yes (mouse, Space) | title 3D ship, console and flight correct | **yes** (laser on mouse Select; 4 channels at 48 µs, own voice modules) | not tested | Recipe: open `:0`, open `!AUélite`, run `!élite`, click the icon-bar icon, press Space → Commander Jameson status screen (docked at Lave); F1 launches (silent); mouse Select fires the laser (A does not). Needs ARM2 prefetch: the loader patches the next instruction. |

Desktop: RISC OS 3.11 and 2.00 both reach the desktop with the icon bar; the mouse pointer moves and Select clicks work.

## Scripted smoke tests

`MACARCH_GAME_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter GameSmokeTests` (in `Packages/ArchimedesCore`, about 15 s) boots RISC OS 3.11 from a CMOS reset and drives each game to gameplay. It writes screenshots, frame checksums and an event log per game to `tests/reports/games/`. Checks:

| Game | Checks |
| --- | --- |
| Repton 3 | Reaches the level; walking right (X) changes the screen. |
| Elite | Loads from the Filer, Commander screen, launch (F1); firing the laser produces non-silent sound. |
| Lemmings | Loads from the Filer, START, level preview, level: timer 1 armed at 234 lines (panel palette split); lemmings move. |
| Holed Out | Boot, `Cram` written to the disc, self-reboot, menus through to hole 1 (course dialog verified by pixel), club selected, a shot played with the middle button (stroke count changes). |

Desktop clicks steer by the VIDC hardware-cursor position (`VIDC.pointerPosition`); in-game moves are relative. All guest input is scripted, so the runs are deterministic.

## RISC OS 2.00

The scripted smoke tests run on both ROM profiles (`test<Game>OnRISCOS2`).

| Game | RISC OS 2.00 | Notes |
| --- | --- | --- |
| Repton 3 | **yes**: level, movement | Same recipe as 3.11. |
| Lemmings | **yes**: menu, preview, level (panel split) | Its mouse scale differs on 2.00; START is at game coordinates (31, 149) on both ROMs. |
| Holed Out | **yes**: menus, hole 1, a shot played | Pointer moves are about a third as far per count; scripts scale them by 3. |
| Elite (Acorn User Aug 95 disc) | **no** (disc, not emulation) | The 1995 cover disc runs its own ArcFS Filer extension, which fails under RISC OS 2 ("Syntax: *Filer_OpenDir <full dirname>") before Elite can be opened. |

Desktop differences the scripts account for: RISC OS 2 boots in a different mode (368 px wide frames at 2x), has no Apps icon, and puts Filer windows elsewhere.

## Machine models

Verified with RISC OS 3.11 and 2.00 unless noted (tests in `MemorySizeTests`, `MachineModelTests`, `HardDiscROMTests`, `ModelSnapshotTests`).

| Configuration | Result |
| --- | --- |
| 512 KB, 1 MB, 2 MB, 4 MB (one MEMC) | Boots on both ROMs; the banner reports the size. |
| A540, 4 and 8 MB | Boots on both ROMs with the size reported. |
| A540, 16 MB | RISC OS 3.11 reports 16384K. RISC OS 2.00 reports 8192K: the A540 shipped with RISC OS 2.01, so this may be a limit of 2.00 rather than the emulation (unconfirmed). |
| ARM3 (any ARM2 model) | RISC OS 3.11 enables the cache (`*Cache` → "Cache on"). A BASIC loop runs about 4.5 times faster than on an ARM2. |
| 400 series, ST506 hard disc | A formatted image mounts on both ROMs. `*Save` and `*Load` of 128 KB (multi-sector transfers across tracks and heads) round-trip, and a file saved under 3.11 is read under 2.00. A blank image gives "Disc not understood" (3.11), as an unformatted drive would. |
| A5000, A3010, A3020, A4000 (RISC OS 3.11) | Boot to the desktop with the floppy drive. The 82C711 floppy controller reads and writes ADFS discs (Read ID at the matching data rate, DMA through ADFS's FIQ handler with terminal count). IDE (A5000, A3020, A4000): a formatted drive mounts, and 128 KB round-trips. The A3010 has no IDE ("Bad drive" for :4, as on the real machine). |
| A5000 family, RISC OS 2.00 | Reaches the desktop, but its ADFS predates the 82C711: no floppy or IDE. The real machines needed RISC OS 3. |

### Games on the A5000

The scripted smoke tests also run on an A5000 (ARM3, 12 MHz memory, the 82C711's floppy controller): Repton 3, Elite, Lemmings and Holed Out all pass (`test<Game>OnA5000`). Holed Out needed the same rule as on the WD1772, now in the 765 as well: a write to a missing standard sector on a formatted track creates it.

## The wider collection (2026-10-21)

RISC OS 3.11 on an A3000 (2 MB) unless noted. Started from the desktop: F12, `*Filer_Run ADFS::0.$.<app>`, then Return on an empty line (the same as double-clicking the application). Scripted in `CollectionSmokeTests` (`MACARCH_GAME_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter CollectionSmokeTests`).

| Title | Image | Result | Notes |
| --- | --- | --- | --- |
| Zarch (Play It Again Sam 2, disc 1) | ADFS E | **yes**: menu, demo prompt, landscape | Press 1 on the compilation menu, Space past the demo prompt. |
| Master Break, Repton 2 (PIAS 2, disc 1) | ADFS E | **yes**: title screens | Both decompress bit by bit ("Please wait a mo...."): about two and a half minutes. The CPU's cycle counts were checked against the ARM2's (LDR, LDRB, LDM with PC), so this is the original's speed, not the emulator's. |
| ArcPinball (PIAS 2, disc 2) | ADFS E | **yes**: coin-door menu in its 848 x 299, 8 bpp mode | Draws its own pointer. |
| Superior Golf, Zelanites (PIAS 3, disc 1) | ADFS E | **yes**: golf menu, Zelanites title | |
| Letrouve, Top Banana (PIAS 3, disc 2) | ADFS E | **yes**: titles | |
| Paradroid 2000 | ADFS E | **yes**: title, Return, the deck | |
| Pacmania | ADFS D, 5120 bytes short | **yes**: attract demo | The image lacks its last track; MacArch reads such images with that track unformatted (see Play It Again Sam 1 below). |
| Speedball 2 | ADFS E, 5120 bytes short | **yes**: Bitmap Brothers intro | As Pacmania. |
| Sim City (Krisalis) | ADFS E, 5120 bytes short | **yes**: New City dialog, map | Open the disc's directory first, so the Filer sees its `!System` (otherwise "System resources cannot be found"). The map's colours and the earthquake reported in the first month are not verified against a real machine. |
| UIM | ADFS D | **yes**: title | |
| UIM | HFE (HxC, MFM) | **yes**: title | All 800 sectors decode with good CRCs. The HFE is a different dump from the ADF: they differ in the free space map and in some file data. |
| Magnetic Scrolls Collection (disc 1) | ADFS E | **yes on RISC OS 2.00; RISC OS 3.11 needs a 160K screen** | The loading sheet asks for "a 160k screensize". RISC OS 2 keeps the configured 160K; RISC OS 3.11's desktop gives the screen only what the mode needs (80K here), and the game draws past the end of its screen: "abort on data transfer at &2BF64" (a user-mode read of &2000000), then an address exception from its ticker after it exits. Grow the screen first (drag it in the Task Manager, or `SYS "OS_ChangeDynamicArea",2,&14000` from BASIC) and it runs, though its menu then sits lower on the screen. |
| Sim City 2000 (A5000 version) | ZIP of `!SC2000` with RISC OS filetypes | **yes**: title, menu, GOODCITY loaded | Build a hard disc from the archive (Hard Disc ▸ New Hard Disc from Files…, or `macarch-cli hard-disc-create sc2k.hdf --ide --from …zip`). Needs an A5000 (or A4000) with 4 MB ("Application needs at least 3008K") and a multisync or VGA monitor: on a standard monitor it shows only the top half of its 640 x 512 picture. |

## More of the collection (2026-10-22)

RISC OS 3.11 on an A3000 (2 MB). Scripted in `CollectionSmokeTests`. Discs are swapped as a person would: out, a pause, then in, and only when the game asks.

| Title | Image | Result | Notes |
| --- | --- | --- | --- |
| Apocalypse | 2 x ADFS E | **yes**: planet menu | Asks for the PLANETS disc after the title; Space twice after inserting it. |
| Gods | 2 x ADFS E | **yes**: main menu, Top Ten | Space past the passwords notice and again after the intro; then "Please insert disc 2". Asks for disc 1 ('Gods1') if disc 2 goes in before it's asked for: the intro still loads from disc 1. |
| Cannon Fodder | 3 x ADFS E | **yes**: the recruitment hill | Disc 2 after the intro. Disc 3 not reached. |
| Play It Again Sam 1: Conqueror, Hostages | 2 x ADFS (D and E), both 5120 bytes short | **yes**: Conqueror's battlefield, Hostages' embassy briefing | Run by disc name (`ADFS::Sam1Boot.$.!Hostages`, as the Filer does), or `<Obey$Dir>` follows drive 0 to the data disc. Hostages' loader verifies track 79 side 1 with ADFS_DiscOp and expects it to fail: on the original disc it is unformatted (the reason these images are short). If the verify succeeds it corrupts itself and drops into BASIC. MacArch used to read the missing track as zeroes; now it is unformatted until written or formatted. |
| Play It Again Sam 1: No Excuses, Rotor | ADFS D | **yes**: menu, title | |
| Xenon 2 (1997 update, split onto two 800K discs) | 2 x ADFS E | **yes**: title and credits | Open the disc's directory first: the launcher (a module task) puts a sprite icon on the icon bar, and the sprite only exists once the Filer has seen `!Xenon2`. Click the icon; ADFS then asks for 'XenonData' and 'Xenon2' in turn. |
| Stunt Racer 2000 | 2 x JFD | **yes**: the menu | Insert disc 2 only when "Please insert Disk Two" shows, then click. Swapping while it is still loading its sprites from disc 1 corrupts the system sprite area, and the menu dies with an address exception in OS_SpriteOp. |
| Wolfenstein 3D (A3000) | 4 x ADFS E | **yes** (played by the user, RISC OS 2) | |
| Doom Trilogy (R-Comp, 1998) | ZIP of `!DoomInst` and IWADs | **installs; doesn't start** | Build a hard disc from the ZIP (120 MB IDE) on a 4 MB A5000 with a multisync monitor. `!DoomInst` installs the Doom+ player, network drivers and extras (it then wants the Ultimate Doom CD, which isn't needed: the IWADs are on the disc). Doom+ needs `System:Modules.BorderUtil` on RISC OS 3.1 (window manager before 3.20), which comes from Acorn's `!System`; with no `!System` on the disc it stops with "Filing system or path System: not present". |
