# Econet: research notes

These notes were gathered before Econet was implemented (2026-10-24). They are facts only: no GPL code was copied. Sources are in brackets.

## Hardware

- **ADLC:** an MC68B54 at **&33A0000**, IOC bank 2, sync cycle type. It is fitted only if the Econet module is present.
  - Sources: A3000 TRM p.8 (0480,055); RISC OS `hdr/IO/IOC-A1`, `IOC-A500` and `IOEB`, which all define `EconetController * &033A0000`.
- **Registers:** the chip is 8-bit on BD0-7. Only LA2/LA3 select its registers (RS0/RS1), so the four registers mirror through the bank, and RISC OS uses LDRB/STRB.

  | Offset | Write | Read |
  |---|---|---|
  | +0 | CR1 | SR1 |
  | +4 | CR2/CR3 | SR2 |
  | +8 | TxByte | RxByte |
  | +C | CR4/TxLast | |

  Sources: Econet module `s/Memory`; MAME `bus/archimedes/econet/slot.h`.
- **Fitting:**
  - A305/310/440, A3000 and A5000 use the internal 17+5-way header. It takes the ADF10 module, the same one the BBC Master uses (A3000 TRM p.21-22).
  - A3020/A4000 use the AEH52 module (Acorn 0494,204).
  - The A5000 header rests on MAME only, because no A5000 TRM text was found.
  - The internal module has no podule ID. Only the Risc PC/A7000 network-slot card is a podule (product type 7).
  - The same header also takes the RTFM joystick and MIDI boards, which is why Arculator's bank 2 handler serves the joystick.
- **Interrupts:** the ADLC's /IRQ goes to IOC FIQ bit 2 (EFIQ, A3000 TRM p.10-11). There is no IRQ.
- **Clock:** the network clock drives RxC and TxC. A monostable gives DCD when the clock is absent, which shows as SR2 bit 5, and RISC OS then reports "No clock". The collision detector drives /CTS (SR1 bit 4).
- **Detection:** RISC OS's Econet module (s/Econet) works as follows:
  1. It writes CR1=&F8 and CR2=&7F, then reads SR1. Any of bits &ED set means no hardware.
  2. It reads SR2. Any of bits &DB set means no hardware.
  3. It writes CR4=0 and compares SR1, SR2, RxByte and the CR4 address. If all read the same value and it is 0, there is no hardware.

  Bank 2 reading &FF, as it does today, fails the first test cleanly, so the module doesn't start.

## How RISC OS drives it

- **ROM modules:** Econet, NetFS, NetFiler, NetPrint, NetStatus and BBCEconet are in ROM in RISC OS 2.00 and 3.1x. RISC OS 3.10 also has BroadcastLoader. The 3.10 versions are Econet 5.62 and NetFS 5.78.
- **FIQ:** the Econet module claims FIQ and runs the whole four-way handshake as an FIQ state machine, one ADLC interrupt at a time.
  - It uses 2-byte mode with prioritised status.
  - It busy-waits on IOC Timer 0 for the 40 µs turnaround (`TurnAroundDelay`).
  - It polls CTS.
  - Each byte must be serviced within roughly one byte-time, which is 40-80 µs at 100-200 kbit/s.
  - The floppy driver borrows FIQ through Service_ClaimFIQ.
- **Station and network numbers:**
  - The station number is in **CMOS byte 0** and is set with `SetStation`, not `*Configure`. A value of 0 or 255 makes the module use station 1.
  - CMOS bytes 1-4 hold the file and print server station/net (or names). Bytes 153-172 hold the server names.
  - The network number comes from a bridge (port &9C), or is 0 when there is no bridge.

## Protocol

- **Four-way handshake:** a transmission is a scout, an acknowledgement, the data, then a final acknowledgement.
  - The scout is dst stn, dst net, src stn, src net, control (bit 7 set) and port.
  - The acknowledgements carry the four address bytes only.
  - The data frame is the four address bytes plus the payload.
  - No acknowledgement to the scout gives "not listening".
  - Sources: PRM ch.47; mdfs.net Econet Packets.
- **Broadcast** goes to station &FF, as a single frame.
- **Immediate operations** go to port 0, with control &81-&89 (peek, poke, JSR, ... MachinePeek). An Archimedes answers MachinePeek with machine type &0007.
- **Ports:**

  | Port | Use |
  |---|---|
  | &99 | file server command |
  | &90 | reply |
  | &9C | bridge |
  | &9E/&9F | printer server status |
  | &D1 | printer server data |
  | &B0/&B1 | FindServer |
- **File server requests:** reply port, function, URD, CSD, LIB, then arguments. The reply is command code and return code, then the data or a CR-terminated error.
  - `*I AM` is function 0 with the text of the command.
  - The core function codes are 1 Save, 2 Load, 3 Examine, 6/7 Open/Close, 8-11 byte and block I/O, 14 disc names, 18/19 object info, 21 user environment and 23 logoff.
  - Sources: mdfs.net FSOps; SJ Research MDFS manual ch.10.
- **AUN** is Econet over UDP on port 32768. It has an 8-byte header: opcode, port, control, flags, then a 32-bit sequence number.
  - The opcodes are 1 broadcast, 2 data, 3 ack, 4 nak, 5 immediate and 6 immediate reply.
  - The station number is the last octet of the IP address.
  - BeebEm uses this through `Econet.cfg`, as does PiEconetBridge.
  - Source: RISC OS AUN `Net/h/module`.

## Other emulators

- **Arculator, ArcEm and Eichhoernchen:** bank 2 is unimplemented in all three; it reads &FF or &FFFFFFFF.
- **RPCEmu:** no Econet.
- **MAME** (`aa310.cpp`) has an MC6854 on IOC peripheral 2, with its IRQ wired to FL.

## MacBeeb's model, which suits MacArch too

MacBeeb emulates the ADLC and the line, and leaves the protocol to Acorn's own software:
- Bytes are byte-timed symbols on a shared bus, with collisions.
- Stations run in fixed lockstep quanta, shorter than the bus delay, so results are deterministic.
- The guest ROMs do the four-way handshake themselves. Faking it, as BeebEm does, is what makes BeebEm unreliable.

Details that mattered there:
- /CTS follows the RTS *output*, which stays up until the closing flag, not the RTS bit.
- A three-symbol receive hold-back, so the last byte arrives with its frame-valid bit.
- Idle (15 one-bits) is timed from the later of the last symbol and receiver-enable plus the line delay.
- Prioritised status and latched interrupt causes.

At MacArch's 24 MHz, one bit at 200 kbit/s is 120 ticks. A scout's "not listening" window is 15 bits, or 1,800 ticks, and the lockstep quantum has to stay well under half of that.

## Level 4 File Server

This is Acorn's file server for an Archimedes, developed with Oak Solutions. Its first release was in 1990. Sources: the Acorn product sheet APP331; the AUN/Level 4 Release Note (0484,660, Dec 1993); StarDot threads t=7285 and t=19428.

**Machine requirements**
- Any RISC OS machine with 1 MB or more, plus a disc to serve.
- It runs either on a dedicated machine (it can run without a keyboard, with a log file) or in the background on the network manager's own desktop.
- 1 MB can run !Server or !Spooler, but not both. The AUN modules need 2 MB.
- RMASize should be configured to 1024K.
- It needs !System with ABCLib and WimpMan.

**What it serves**
- It exports any hard or floppy disc on ADFS, SCSI, CDFS or Nexus, except L-format discs. The exports are listed in the `Exports` file inside `!Server`.
- An exported root directory is limited to 77 objects.
- It serves BBCs (NFS 3.6 or later), Masters and Archimedes. Both RISC OS 2 and RISC OS 3 clients are supported.

**Applications and versions**
- The applications are !Server, !Spooler (print queues), !Manager (users and access), !MailMan, SetStation and a stand-alone `Level4` program.
- Issue 2 was !Server 1.10 to 1.24.
- Release 3 was !Server 1.32 (Jan 1994), with Econet 5.56, NetFS 5.60, NetPrint 5.38 and NetUtils for RISC OS 3.1 clients.
- Acorn's 1.33 patch (4corn `acornftp/riscos/releases/networking/level4`, Spark archives) is needed only with RISC OS 3.5 or later.
- Network Solutions later sold "Advanced Level 4" (2.1x), which is not covered here.

**Known issue:** RISC OS 3.10 and 3.11 clients need NetUtils loaded, or files of 128K or more can be corrupted.

**Downloads** (all 800K ADFS E images, despite the `.adl` names):
- **Issue 2:** acorn.huininga.nl `/pub/disks/originals/Acorn/Econet Level 4 Fileserver Issue 2/` (AUN, FileServer and Supplemental discs).
- **Release 3:** arcarc.nl `archive/Apps/A/AUN Level 4/` (AUN, Level 4, Support and AppAcc discs, plus the release note).
- MacArch reads all of these discs.

## As built (2026-10-24)

See `docs/progress.md`. Two differences from MacBeeb's ADLC were needed by RISC OS (TDRA and RDA as level interrupts; a station's receiver hearing its own transmission).

**Level 4, as set up by MacArch** (`ArchimedesCore/Econet/Level4.swift`, tested by `Level4Tests` against Release 3):
- The disc is read with `ADFSDiscReader` (E format: new map, fragment addresses resolved). Release 3's `!Server.!Run` refuses RISC OS before 3.10; Issue 2's loads Econet 5.56 and NetFS 5.60 from its own !System instead.
- The server's hard disc (old map, 20 MB ST506, or 40 MB IDE on an A5000) holds !Server, !System, !Manager, !NetUtils, !Spooler and !Merge, and a `$.!Boot` Obey file with boot option 2 (*Opt 4,2): `/ADFS::4.$.!System`, `Run ADFS::4.$.!Server.!Boot`, `Desktop /ADFS::4.$.!Server`. The server starts in the desktop, its icon reading "Ready", in about 30 s from power-on.
- The supplied `Exports` exports `ADFS 4 $`, so the clients see the whole disc (77 objects in the root at most). The supplied `Users` file has SYST (no password), BOOT, Class1-3 and GUEST.
- CMOS (`MachineConfiguration.cmosSettings`, kept at power-on, reset and through a CMOS reset): FileSystem 8 (ADFS, byte 5), Drive 4 (byte 11 bits 0-2), Boot (byte 16 bit 4), RMASize 1024K (byte 146, in pages: 32K pages at 4 MB). Byte numbers are OS_Byte 161's; the clock chip's RAM has bytes 0-191 at &40 and 192-239 at &10 (PRM, CMOS RAM allocation).
- A client (RISC OS 3.11, CMOS defaults: file server 254) does `*NET`, `*I AM SYST`, `*CAT` and sees `Net::FileServer.$`.

## Joining MacBeeb's networks (design)

- **Time:** network ticks are 24 MHz. MacBeeb's 2 MHz cycles are ×12 exactly. Both use a 16 µs quantum and a 16 µs line delay.
- **Line:** `EconetLine` talks to stations through `EconetInterface` (station number, local time, set line state, take outbox, deliver). A link to another app is one more interface: per quantum it gives the other app what this line's stations sent, and plays in what the other app's stations sent, a quantum late as any station's symbols are.
- **Lockstep across apps:** both apps' lines must step quantum by quantum together, or the 15-bit idle window (75 µs at 200 kbit/s) is missed. A shared-memory barrier (as MacBeeb's worker threads use) between the two processes would keep them deterministic; sockets are likely too slow at 62,500 round trips a second.
- **AUN** (UDP 32768) is the alternative for real networks (BeebEm, PiEconetBridge): whole frames, not symbols, so a gateway would play the four-way handshake for the other side. Not deterministic.
- **Projects:** `NetworkProject` keeps MacBeeb's shape (nodes with kinds, station numbers and canvas positions), so a shared network file could hold both apps' machines.

