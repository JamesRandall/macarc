# LinuxArch

MacArch for Linux: the same `ArchimedesCore` emulation, `macarch-cli` and
`macarch-mcp`, with a GTK4 and libadwaita app in place of the Mac one. It's
another product of this package, built on Linux (the manifest swaps the Mac
app for it there), and follows LinuxBeeb's layout and conventions.

## You need

A recent Linux with GTK 4.14+ and libadwaita 1.8+ (Ubuntu 26.04 has both),
and swift.org's Swift 6.2+ toolchain (6.4.1 is what it's built with).

```sh
sudo apt install libgtk-4-dev libadwaita-1-dev libsdl3-dev libepoxy-dev \
    libwayland-dev zlib1g-dev libcurl4-openssl-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-libav
```

The GStreamer plugins are for video recording: MP4 (H.264 with AAC) needs
x264 (plugins-ugly) or openh264, and AAC (libav); MOV (ProRes) needs libav.

## Build and run

```sh
swift run linuxarch               # or: make run
make install-user                 # ~/.local: the app, its desktop entry, icons and file types
sudo make install                 # /usr/local (PREFIX=… for elsewhere)
make deb                          # .build/deb/linuxarch_VERSION_ARCH.deb
make flatpak                      # needs flatpak-builder and Flathub's GNOME 50 SDK
make test                         # the core's tests, then the agent tools'
```

The installed programs carry the Swift runtime (`--static-swift-stdlib`), so
they need only the system's libraries. `make install` includes ArcLibre (its
2 MB and 4 MB ROMs and the 2 MB ROM's extras disc, which Disc ▸ Insert
ArcLibre Extras Disc puts in) when `Apps/MacArch/Resources/ArcLibre` has them
(they're git-ignored, as for the Mac build; `scripts/update-arclibre.sh`
copies them from an ArcLibre release); without them, the first window asks
for a ROM. The same
goes for Acorn's Level 4 File Server disc (`Apps/MacArch/Resources/Level4.adf`):
without it, the Network Studio sets a file server up from a Level 4 disc image
you choose. The Game Library's catalogue and covers come from
`Apps/MacArch/Resources/Classics` and `Covers`.

Settings are JSON in `$XDG_CONFIG_HOME/linuxarch/settings.json`; ROMs, CMOS
profiles, hard discs, quick saves, the Game Library (`Library/Classics` and
`Library/MyGames`) and Internet Econet room credentials (`Econet/rooms.json`,
readable only by you) are in `$XDG_DATA_HOME/linuxarch` (the Mac app's
Application Support/MacArch), as is the agent socket that `macarch-mcp
--attach` looks for there. New networks go in Documents/LinuxArch Networks.

`LINUXARCH_SELFTEST=out.png` runs the first window's machine and writes its
frame, the picture as drawn, the window and a report, then quits (see
`SelfTest.swift` for its options: ROM, model, disc, text to type, style,
games to add and play, and the dialogs and windows to open and capture). With
`MACARCH_AGENT_SOCKET` set it serves agents too, so a test can drive it with
`macarch-mcp --attach` while it runs.

## What maps to what

| MacArch (`Apps/MacArch`) | LinuxArch (`Apps/LinuxArch`) |
| --- | --- |
| `UI/MacArchApp.swift` (scenes, menus) | `Sources/LinuxArchApp.swift` (the app, its actions and shortcuts), `Sources/MachineWindow.swift` (the window and its menus) |
| `UI/MachineToolbar.swift` | `Sources/MachineWindow.swift` (the header bar and lights) |
| `Services/MachineController.swift` | `Sources/MachineController.swift`, nearly line for line (its dialogs are async) |
| `Services/EmulatorHost.swift` | `Sources/EmulatorHost.swift`, without network stations |
| `Rendering/EmulatorView.swift` | `Sources/EmulatorView.swift` (a GL area), `Sources/PointerLock.swift` (Wayland pointer lock) |
| `Rendering/Renderer.swift` (Metal) | `Sources/Renderer.swift`, and `CArchGL` (OpenGL; the shader in GLSL) |
| `Audio/AudioOutput.swift` (AVAudioEngine) | `Sources/AudioOutput.swift` (SDL3, so PipeWire or PulseAudio) |
| `UI/KeyMap.swift` (Mac key codes) | `Sources/LinuxKeyMap.swift` (Linux key codes) |
| `Services/AppSettings.swift`, `KeyboardSettings.swift`, `ROMLibrary.swift`, `WhatsNew.swift` | Same names, nearly unchanged (`Preferences` for UserDefaults) |
| `UI/SettingsView.swift`, `UI/ROMViews.swift` | `Sources/PreferencesDialog.swift` |
| `UI/ConfigureMachineWindow.swift` | `Sources/ConfigureMachineDialog.swift` |
| `UI/WelcomeScreen.swift` (an Archimedes' card) | `Sources/SetupPage.swift` |
| `UI/RewindSheet.swift` | `Sources/RewindDialog.swift` |
| `UI/DebuggerModel.swift`, `UI/DebuggerWindow.swift`, `UI/BasicDebuggerViews.swift` | `Sources/DebuggerModel.swift` (the same), `Sources/DebuggerWindow.swift` (machine code and BASIC) |
| `DiscContents/DiscContentsModel.swift`, `DiscContentsWindow.swift` | `Sources/DiscContentsModel.swift` (with an undo stack of its own), `Sources/DiscContentsWindow.swift` |
| `Services/VideoRecorder.swift` (AVFoundation) | `Sources/VideoRecorder.swift` (GStreamer), `System/CGStreamer` |
| `Services/AppAgent.swift`, `AppMachineDirectory.swift`, `UI/AgentWindows.swift` | `Sources/AppAgent.swift`, `Sources/AppMachineDirectory.swift`, `Sources/AgentWindows.swift` |
| `Library/` (Game Library, Classics, My Games, playing) | `Sources/ClassicsLibrary.swift`, `MyGames.swift`, `GameLibrary.swift`, `ClassicPlay.swift`, `GameLibraryWindow.swift`, `GameDetailsDialog.swift` |
| `Network/`, `Services/NetworkHost.swift` (the Network Studio) | `Sources/NetworkProject.swift`, `NetworkPackage.swift`, `NetworkSession.swift`, `NetworkSession+Internet.swift`, `NetworkHost.swift`, `RecentNetworks.swift`, `ThumbnailCache.swift` (all much the same); `NetworkStudioWindow.swift` (the window, tiles and focus), `NetworkCanvasView.swift`, `NetworkPanels.swift` (inspector, traffic, Mandelbrot), `NetworkDialogs.swift` (new network, sharing, joining) |
| `UI/AboutPanel.swift`, `UI/WhatsNewView.swift` | `Sources/AppDialogs.swift` (with the shortcuts dialog) |
| `Services/SelfTest.swift` | `Sources/SelfTest.swift` |
| `Services/Updates.swift` (Sparkle) | None: packages are updated by the package manager |
| `Resources/AppIcon.icon`, `Tools/icon/draw.py` | `data/icons`, `Tools/icon/draw-svg.py` |

`Sources/GLib` is the layer over GTK (LinuxBeeb's): GObject signals to Swift
closures, GActions and menus, file dialogs, alerts, the clipboard, and GLib's
main loop running libdispatch's main queue (so `DispatchQueue.main` and the
main actor work). `observe` re-runs UI updates when `@Observable` models
change, as SwiftUI does.

## How the app differs from MacArch's

- **Shortcuts:** in the Archimedes' window, Ctrl and Alt are the
  Archimedes', so ⌘ becomes Ctrl+Shift and ⌘⇧ or ⌘⌥ Ctrl+Shift+Alt (as in
  LinuxBeeb and GNOME's Terminal); zoom is Ctrl+0/+/−, fullscreen F11,
  preferences Ctrl+, (`LinuxArchApp.shortcuts`, and Help ▸ Keyboard
  Shortcuts). Ctrl+Shift+M releases a captured mouse.
- **The mouse:** a click captures it; on Wayland the pointer is held still
  with the pointer-constraints protocol (GTK has no pointer lock). Left is
  Select, middle Menu, right Adjust (Preferences can swap Menu and Adjust).
- **The keyboard:** PC keys map by position (End is Copy, Pause is Break, the
  ISO key left of Z is £), or by character in your layout.
- **The header bar** has the Mac toolbar's common items; the main menu has
  the rest of the Mac's menu bar.
- **Opening at launch:** a new window switches straight on with the last
  ROM; until there's one, it shows a page for adding ROMs.
- **Room credentials** (for the Internet Econet) are kept in a file only you
  can read, not a keychain.
- **The Network Studio's canvas** has its cards as widgets placed and scaled
  on a `GtkFixed`, over a drawing area that draws the grid and the bus and
  takes the pointer. A network is a folder (`.macarchnet`), so Open Network
  chooses a folder. Invitation links (`macarch://join…`) open the Join window
  (the desktop entry handles `x-scheme-handler/macarch`).
- **Disc Contents** drags files out through a temporary folder (with their
  RISC OS types in their names), as LinuxBeeb does, and its undo is its own.
- **Opening with** an Archimedes, the Game Library or the Network Studio is a
  choice in Preferences ▸ General (the Mac app's opening screen; there's no
  separate welcome screen: a window without a ROM is the setup page).

## How the shared code changed for Linux

Each change is a `#if canImport(…)` or `#if os(Linux)` guard, so macOS builds
as before:

- `Package.swift`: on Linux, the Mac app's target and product are replaced by
  LinuxArch's (Sparkle stays declared, so `Package.resolved` is the same;
  `LINUXARCH_OFFLINE` leaves it out for offline builds).
- `Packages/ArchimedesCore/Package.swift`: a `zlib` system library module on
  Linux (macOS's SDK has one), so the core uses zlib rather than its WASI
  fallback (snapshots and rewind stay compressed).
- `Econet/Internet`: `import FoundationNetworking` where it's separate;
  `KeychainCredentialStore` only where there's Security, and a
  `FileCredentialStore` (a 0600 JSON file) for elsewhere.
- `Econet/LockstepWorkers.swift`: performance cores from `sysctlbyname` only
  on Darwin.
- `Media/ADFSStore.swift`: `HostFiles.openFD` rather than `Darwin.open`.
- `Portable/HostFiles.swift`: `setModificationDate` (Linux's Foundation can't
  set dates before 1970 that aren't whole seconds), used by disc export.
- Tests: Linux bundles' resource paths, raw deflate without
  `NSData.compressed`, and test classes other tests instantiate get an
  initialiser swift-corelibs-xctest lacks.
- `Tools/MacArchAgent`: Glibc sockets for the agent socket, POSIX sockets for
  the debug adapter's TCP port where there's no Network framework, and the
  XDG data directory on Linux.
