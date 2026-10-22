# Implementation plan

Layout: `Packages/ArchimedesCore` (UI-free core and tests), `Tools/macarch-cli`, `Tools/macarch-mcp`, `Apps/MacArch` (SwiftUI + Metal + AVAudioEngine). The root `Package.swift` builds the tools and the app.

Core design:
* `ARM2<Bus>`: 26-bit ARM2 interpreter (generic over its bus, specialised for `MEMC`). The PC and PSR are stored separately and R15 is composed on read.
* Guest time is a 24 MHz master tick counter in `MEMC.ticks`. Every bus access charges its own cost. A fixed-slot `Scheduler` drives IOC timers, VIDC raster lines, KART bytes, FDC byte/step timing, sound DMA and scripted input.
* VIDC renders one raster line at a time from MEMC DMA pointers, so palette changes take effect per line. It publishes `VideoFrame`s with suggested aspect scaling.
* Floppy images are read-only bases with an in-memory copy-on-write overlay.

Next milestones, in order:
1. Run Repton 3 and Lemmings from the desktop and record the results (Phase 4 gate).
2. Validate sound against real output and add WAV capture.
3. Model mid-line palette changes and FIFO/border soft-scroll edge cases if games need them.
4. ~~JFD (Holed Out) track-level format support.~~ Done 2026-10-20.
5. ~~Snapshots~~ (done 2026-10-20), keyboard mapping UI, absolute-mouse option, packaging and signing.
