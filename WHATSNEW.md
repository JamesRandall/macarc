# What's New in MacArch

<!--
One section per release, newest first: "## VERSION" (optionally "— DATE"),
then a line of introduction if wanted, then "- " bullets. Inline Markdown
(**bold**, *italic*, `code`, [links](https://…)) is fine. The app shows the
sections since the version a user last ran; scripts/release.sh uses the
release's section for the GitHub release and Sparkle's update window, and
won't build a release without one.
-->

## 0.3.0

Archimedes on a network: Econet, Acorn's Level 4 File Server, and a Network Studio like MacBeeb's.

- **Econet:** machines on a network have Econet modules, and RISC OS's own network software talks over the cable. RISC OS 2 and 3 machines talk to each other.
- **Network Studio:** File ▸ New Network… (⇧⌘N) starts from Two Archimedes, School Classroom, The Archimedes Family or an empty network. Draw machines on a canvas, or see them as tiles or one at a time. Traffic shows every frame on the cable. Networks save themselves as `.macarchnet` documents in Documents ▸ MacArch Networks.
- **Distributed Mandelbrot:** a new template, MacBeeb's demo for the Archimedes. Four A3000s boot from the file server and draw the Mandelbrot set between them over Econet, for a Guide that types `*Mandel`. Switch one off part way and its tiles go to the others; switch it back on and it joins in. The studio's new Mandelbrot view follows the render from the frames on the cable, and Traffic reads its messages.
- **Network boot:** a machine's inspector sets it to boot from the network: NetFS logs on to the file server as BOOT at power-on and runs its boot file, as a school's machines did.
- **File server:** set a network's File Server up with Level 4 from your own Level 4 disc (Release 3 or Issue 2). MacArch builds a hard disc that starts the server, and the other machines log on with `*I AM SYST`.
- **Faster big networks:** when a network can't keep up on one processor core, its machines are spread over more.
- **AI agents:** every MCP tool can drive a network's machine, and new tools list, power, pause and trace networks, and set up the file server.
- **ADFS floppies as sources:** New Hard Disc from Files… and Add Files to Hard Disc… also take ADFS D and E floppy images.
- **macOS 26:** MacArch now needs macOS 26, as MacBeeb does.

## 0.2.0

Easier software from archives, and more games working.

- **Add files to a hard disc:** File ▸ Hard Disc ▸ Add Files to Hard Disc… copies ZIP archives or folders onto a drive you already have. It makes any missing folders and tells you which files it will replace. You can also drop ZIPs on the window.
- **Compacting:** when there's room but not in one piece, MacArch offers to compact the drive first, as `*Compact` does.
- **More ZIPs:** archives using PKZIP 1's "implode" compression (such as Zarch's desktop version) now open, and every file is checked for corruption.
- **Several archives at once:** New Hard Disc from Files… takes more than one ZIP or folder, so Doom and !NetUtils go on together.
- **Copy protection:** disc images missing their last track now behave like the original disc, so Play It Again Sam 1's Hostages and Conqueror load.
- **Games:** Doom, Apocalypse, Gods, Cannon Fodder, Xenon 2, Stunt Racer 2000, No Excuses and Rotor tested and running.

## 0.1.0

The first release of MacArch: the Acorn Archimedes, on your Mac.

- **Machines:** the 300 and 400 series, A540, A3000, A5000, A3010, A3020 and A4000, with ARM2, ARM3 or ARM250, and RISC OS 2 or 3.
- **Bring your own ROMs:** drop ROM images, chip sets or ZIP archives on the welcome screen. MacArch works out the chip order, checks them and keeps a copy.
- **Discs:** ADFS and DOS floppies (ADF, JFD and HFE), hard discs, and new hard discs built from a ZIP or folder of files.
- **Debugger:** disassembly, memory, breakpoints with conditions, step back and reverse continue, and a profiler.
- **AI agents:** an MCP server so Claude Code or Codex can drive the machine.
- **Updates:** MacArch ▸ Check for Updates…, and this window when there's something new.
