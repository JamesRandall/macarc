import ArchimedesCore
import CGtk
import Foundation

/// The application: its windows, its actions and their shortcuts.
@MainActor
final class LinuxArchApp {
    static let shared = LinuxArchApp()

    let app: OpaquePointer
    private var actions: Actions!
    private var mcpSetup: MCPSetupWindow?
    private var agentLog: AgentLogWindow?

    private init() {
        let pointer = adw_application_new(AppInfo.id, GApplicationFlags(rawValue: 1 << 2))!  // G_APPLICATION_HANDLES_OPEN
        app = OpaquePointer(pointer)
        g_set_application_name("LinuxArch")
        onSignal(app, "startup") { [unowned self] in self.startup() }
        onSignal(app, "activate") { [unowned self] in self.activate() }
        connectOpen()
        addOptions()
        onSignal(app, "shutdown") { Preferences.standard.save() }
    }

    /// `linuxarch --new-window` (the desktop entry's action) opens a window
    /// in the running app.
    private func addOptions() {
        g_application_add_main_option(app.cast(), "new-window", 0, GOptionFlags(rawValue: 0), G_OPTION_ARG_NONE,
                                      "Open a new window", nil)
        let callback: @convention(c) (gpointer?, UnsafeMutablePointer<GVariantDict>?, gpointer?) -> gint = { application, options, _ in
            guard let application, let options, g_variant_dict_contains(options, "new-window") != 0 else { return -1 }
            g_application_register(application.cast(), nil, nil)
            g_action_group_activate_action(OpaquePointer(application), "new-window", nil)
            return 0
        }
        la_signal_connect(app.raw, "handle-local-options", unsafeBitCast(callback, to: GCallback.self), nil, nil, 0)
    }

    func run() -> Int32 {
        // GApplication wants argv; it takes file names from it for "open".
        var arguments = CommandLine.arguments.map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        return arguments.withUnsafeMutableBufferPointer { buffer in
            g_application_run(app.cast(), Int32(buffer.count), buffer.baseAddress)
        }
    }

    private func startup() {
        // Ctrl+C in a terminal, or SIGTERM, quits as closing the windows
        // would (settings saved).
        let quit: GSourceFunc = { _ in
            MainActor.assumeIsolated {
                for window in MachineWindow.all {
                    window.forceClose()
                }
                NetworkStudioWindow.closeAll()
                g_application_quit(LinuxArchApp.shared.app.cast())
            }
            return 0
        }
        g_unix_signal_add(SIGINT, quit, nil)
        g_unix_signal_add(SIGTERM, quit, nil)
        UI.addCSS(Self.css)
        // The app's icons, wherever it's installed (or in the source tree).
        if let icons = AppPaths.icons {
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), icons.path)
        }
        gtk_window_set_default_icon_name(AppInfo.id)
        addActions()
        addShortcuts()
    }

    private var activated = false

    /// Launched (or the icon clicked again): a window if there isn't one,
    /// which at launch is what Preferences say to open with.
    private func activate() {
        defer { activated = true }
        if let window = MachineWindow.all.last {
            window.present()
            return
        }
        if !activated && LaunchScreen.atLaunch == .games {
            let library = GameLibraryWindow.show()
            if WhatsNew.shouldShowOnLaunch() {
                after(0.5) { WhatsNewDialog.present(parent: library.window) }
            }
            return
        }
        if !activated && LaunchScreen.atLaunch == .network {
            NetworkStudioWindow.showStudio()
            return
        }
        if GameLibraryWindow.isOpen {
            GameLibraryWindow.show()
            return
        }
        newWindow()
    }

    @discardableResult
    func newWindow() -> MachineWindow {
        let window = MachineWindow(app: app)
        window.present()
        if MachineWindow.all.count == 1 {
            if let test = SelfTest.current {
                test.run(window)
            } else if WhatsNew.shouldShowOnLaunch() {
                after(0.5) { WhatsNewDialog.present(parent: window.window) }
            }
        }
        return window
    }

    /// Files from the file manager or the command line: discs, states,
    /// ROMs, BASIC programs.
    private func connectOpen() {
        typealias OpenHandler = @MainActor ([URL]) -> Void
        let handler: OpenHandler = { [unowned self] urls in
            // Invitations (macarch://join…) and networks need no machine.
            var rest: [URL] = []
            for url in urls {
                if JoinRequests.isJoinLink(url) {
                    JoinRequests.shared.handle(url)
                } else if url.pathExtension.lowercased() == NetworkPackage.fileExtension {
                    NetworkStudioWindow.show(url)
                } else {
                    rest.append(url)
                }
            }
            guard !rest.isEmpty else { return }
            let window = MachineWindow.all.last { !$0.machine.isStation } ?? self.newWindow()
            for url in rest {
                window.machine.open(url)
            }
            window.present()
        }
        let callback: @convention(c) (gpointer?, UnsafeMutablePointer<OpaquePointer?>?, gint, UnsafePointer<CChar>?, gpointer?) -> Void = { _, files, count, _, data in
            let handler = Box<OpenHandler>.from(data)
            var urls: [URL] = []
            for index in 0..<Int(count) {
                if let file = files?[index], let path = String(gOwned: g_file_get_path(file)) {
                    urls.append(URL(fileURLWithPath: path))
                } else if let file = files?[index], let uri = String(gOwned: g_file_get_uri(file)), let url = URL(string: uri) {
                    urls.append(url)
                }
            }
            MainActor.assumeIsolated { handler(urls) }
        }
        la_signal_connect(app.raw, "open", unsafeBitCast(callback, to: GCallback.self), Box(handler).retained, releaseBox, 0)
    }

    private var activeWindow: Widget? {
        gtk_application_get_active_window(app.cast()).map { $0.widget }
    }

    private func addActions() {
        actions = Actions(app)
        actions.add("new-window") { [unowned self] in self.newWindow() }
        actions.add("quit") { [unowned self] in self.quit() }
        actions.add("preferences") { [unowned self] in PreferencesDialog.present(parent: self.activeWindow) }
        actions.add("roms") { [unowned self] in PreferencesDialog.present(parent: self.activeWindow, page: .roms) }
        actions.add("shortcuts") { [unowned self] in ShortcutsDialog.present(parent: self.activeWindow) }
        actions.add("about") { [unowned self] in AboutDialog.present(parent: self.activeWindow) }
        actions.add("whats-new") { [unowned self] in WhatsNewDialog.present(parent: self.activeWindow) }
        actions.add("game-library") { GameLibraryWindow.show() }
        actions.add("network-new") { NetworkStartWindow.show() }
        actions.add("network-open") { [unowned self] in NetworkStudioWindow.chooseAndOpen(parent: self.activeWindow) }
        actions.add("network-recent", string: { path in NetworkStudioWindow.show(URL(fileURLWithPath: path)) })
        actions.add("network-studio") { NetworkStudioWindow.showStudio() }
        actions.add("network-join") { JoinRoomWindow.show() }
        // A view of the network open (for self-tests).
        actions.add("network-mode", string: { NetworkStudioWindow.showMode($0) })
        // A station's own window, by its number (for self-tests).
        actions.add("network-station", string: { number in
            for session in NetworkSession.open.values {
                if let node = session.project.stations.first(where: { "\($0.stationNumber ?? -1)" == number }),
                   let controller = session.controllers[node.id] {
                    StationWindows.open(controller)
                }
            }
        })
        // A shelf, and a tile on it selected ("myGames:0"): for self-tests.
        actions.add("game-library-at", string: { target in
            let parts = target.split(separator: ":").map(String.init)
            let library = GameLibraryWindow.show()
            if let tab = parts.first.flatMap(ShelfTab.init(rawValue:)) { library.show(tab: tab) }
            if parts.count > 1, let index = Int(parts[1]) { after(0.3) { library.select(index: index) } }
        })
        actions.add("mcp-setup") { [unowned self] in
            if self.mcpSetup == nil {
                self.mcpSetup = MCPSetupWindow(app: self.app) { [weak self] in self?.mcpSetup = nil }
            }
            self.mcpSetup?.present()
        }
        actions.add("mcp-log") { [unowned self] in
            if self.agentLog == nil {
                self.agentLog = AgentLogWindow(app: self.app) { [weak self] in self?.agentLog = nil }
            }
            self.agentLog?.present()
        }
    }

    /// Quits once every window's disc changes are saved or let go.
    func quit() {
        Task { @MainActor in
            guard await MachineController.confirmQuit() else { return }
            for window in MachineWindow.all {
                window.forceClose()
            }
            NetworkStudioWindow.closeAll()
            g_application_quit(app.cast())
        }
    }

    /// The keyboard shortcuts. In the Archimedes' window, Ctrl and Alt
    /// belong to the Archimedes, so the app's own use Ctrl+Shift (where the
    /// Mac app has ⌘) and Ctrl+Shift+Alt (where it has ⌘⇧ or ⌘⌥), as
    /// LinuxBeeb and GNOME's Terminal do for the same reason.
    static let shortcuts: [(section: String, items: [(title: String, action: String, accels: [String])])] = [
        ("Discs", [
            ("Open a disc", "win.open-disc", ["<Control><Shift>o"]),
            ("New disc", "win.new-disc('e')", ["<Control><Shift>n"]),
            ("Save the disc’s changes", "win.save-disc", ["<Control><Shift><Alt>d"]),
            ("Eject the disc", "win.eject-disc", ["<Control><Shift>e"]),
            ("Show the disc’s contents", "win.disc-contents('floppy')", ["<Control><Shift>i"]),
        ]),
        ("Capture", [
            ("Save a screenshot", "win.screenshot", ["<Control><Shift>s"]),
            ("Copy a screenshot", "win.copy-screenshot", ["<Control><Shift>c"]),
            ("Paste text (typed into the Archimedes)", "win.paste-text", ["<Control><Shift>v"]),
            ("Start or stop recording", "win.record", ["<Control><Shift><Alt>r"]),
            ("Save state", "win.save-state", ["<Control><Shift><Alt>s"]),
            ("Load state", "win.load-state", ["<Control><Shift><Alt>l"]),
            ("Quick save", "win.quick-save", ["<Control><Shift>F6"]),
            ("Quick load", "win.quick-load", ["<Control><Shift>F5"]),
        ]),
        ("Machine", [
            ("Pause or resume", "win.pause", ["<Control><Shift>p"]),
            ("Full speed", "win.full-speed", ["<Control><Shift>f"]),
            ("Mute", "win.mute", ["<Control><Shift><Alt>m"]),
            ("Reset", "win.reset", ["<Control><Shift>b"]),
            ("Power cycle", "win.power-cycle", ["<Control><Shift><Alt>p"]),
            ("Capture or release the mouse", "win.capture-mouse", ["<Control><Shift>m"]),
            ("Rewind 5 seconds", "win.rewind('5')", ["<Control><Shift>Left"]),
            ("Rewind timeline", "win.timeline", ["<Control><Shift>h"]),
            ("Configure machine", "win.configure", ["<Control><Shift><Alt>c"]),
        ]),
        ("Debug", [
            ("Show the debugger", "win.debugger", ["<Control><Shift>d"]),
            ("Break into the debugger, or continue", "win.debug-break", ["<Control><Shift>y"]),
        ]),
        ("View", [
            ("Actual size", "win.actual-size", ["<Control>0"]),
            ("Zoom in", "win.zoom-in", ["<Control>plus", "<Control>equal"]),
            ("Zoom out", "win.zoom-out", ["<Control>minus"]),
            ("Fullscreen", "win.fullscreen", ["F11"]),
        ]),
        ("General", [
            ("New Archimedes window", "app.new-window", ["<Control><Shift><Alt>n"]),
            ("Game library", "app.game-library", ["<Control><Shift><Alt>g"]),
            ("Network Studio", "app.network-studio", ["<Control><Shift><Alt>0"]),
            ("Join an Econet network", "app.network-join", ["<Control><Shift><Alt>j"]),
            ("Close window", "window.close", ["<Control><Shift>w"]),
            ("Preferences", "app.preferences", ["<Control>comma"]),
            ("Keyboard shortcuts", "app.shortcuts", ["<Control>question"]),
            ("AI agent activity log", "app.mcp-log", ["<Control><Shift><Alt>a"]),
            ("Quit", "app.quit", ["<Control><Shift>q"]),
        ]),
    ]

    private func addShortcuts() {
        for section in Self.shortcuts {
            for item in section.items {
                var accels = item.accels.map { strdup($0) } + [nil]
                defer { accels.forEach { free($0) } }
                accels.withUnsafeMutableBufferPointer { buffer in
                    buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { pointers in
                        gtk_application_set_accels_for_action(app.cast(), item.action, pointers.baseAddress)
                    }
                }
            }
        }
    }

    // MARK: Style

    static let css = """
        .emulator-background { background-color: black; }
        .picture-error { color: white; margin: 24px; }
        .lights { margin: 0 6px; }
        .light { min-width: 7px; min-height: 7px; border-radius: 4px; background-color: alpha(currentColor, 0.25); }
        .light.green.on { background-color: #2ec27e; box-shadow: 0 0 3px #2ec27e; }
        .light.orange.on { background-color: #ff7800; box-shadow: 0 0 3px #ff7800; }
        .light-label { font-size: 7pt; font-weight: 500; opacity: 0.6; }
        .setup-card { padding: 6px; }
        .rom-path { font-size: 0.85em; }
        .inspection {
            background-color: alpha(@window_bg_color, 0.85);
            color: @window_fg_color;
            border-radius: 6px;
            padding: 4px 8px;
        }
        .light.agent.on { background-color: alpha(#2ec27e, 0.6); }
        .light.agent.on.busy { background-color: #2ec27e; box-shadow: 0 0 4px #2ec27e; animation: pulse 0.8s ease-in-out infinite alternate; }
        @keyframes pulse { from { opacity: 1; } to { opacity: 0.45; } }
        .agent-light { padding: 0 4px; min-height: 0; }
        button.recording { color: #e01b24; }
        .code { font-family: monospace; }
        .code-small { font-family: monospace; font-size: 0.9em; }
        .error-text { color: @error_color; }
        .disassembly-row { padding: 1px 8px; }
        .disassembly-row.pc { background-color: alpha(@accent_bg_color, 0.12); }
        .disassembly-row.pc.stopped { background-color: alpha(@accent_bg_color, 0.25); }
        .disassembly-row.error-line { background-color: alpha(@error_bg_color, 0.2); }
        .breakpoint-dot { min-width: 10px; min-height: 10px; border-radius: 5px; padding: 0;
                          border: 1px solid alpha(currentColor, 0.25); background: none; }
        .breakpoint-dot.set { background-color: #e01b24; border-color: #e01b24; }
        .breakpoint-dot.disabled { background-color: alpha(#e01b24, 0.3); border-color: transparent; }
        .breakpoint-dot.set.conditional { background-color: white; box-shadow: inset 0 0 0 3px #e01b24; }
        .column-header button { font-weight: bold; padding: 4px 6px; min-height: 0; }
        .changed { color: #ff7800; font-weight: bold; }
        .shelf-title { font-size: 2em; font-weight: 600; }
        .shelf-subtitle { font-size: 1.15em; }
        .tile { padding: 8px; border-radius: 10px; }
        .shelf > flowboxchild { padding: 0; border-radius: 10px; }
        .shelf > flowboxchild:selected { background: none; color: inherit; }
        .shelf > flowboxchild:selected .tile { background-color: alpha(@accent_bg_color, 0.2); }
        .shelf > flowboxchild:drop(active) .tile { background-color: alpha(@accent_bg_color, 0.3); }
        .get-link { color: @accent_color; }
        .cover { filter: saturate(1.2) contrast(1.1); border-radius: 3px; box-shadow: 0 4px 6px alpha(black, 0.35); }
        .cover.not-installed { filter: saturate(1.2) contrast(1.1) brightness(0.94); }
        .placeholder-cover, .archive-cover { border-radius: 3px; box-shadow: 0 4px 6px alpha(black, 0.35); padding: 10px; }
        .placeholder-cover { background-image: linear-gradient(to bottom, #241f38, #0f0d1c); }
        .placeholder-cover .band { background-color: #db5c29; min-height: 3px; }
        .placeholder-cover .cover-title { color: #ffd973; font-weight: bold; font-size: 1.2em; }
        .archive-cover { background-image: linear-gradient(to bottom, #1f2421, #0d120f); padding: 12px; }
        .archive-cover .band { min-height: 4px; }
        .archive-cover .band.green { background-color: #33d17a; }
        .archive-cover .band.cyan { background-color: #33c7de; }
        .archive-cover .band.blue { background-color: #3584e4; }
        .archive-cover .band.orange { background-color: #ff7800; }
        .archive-cover .band.yellow { background-color: #f6d32d; }
        .archive-cover .archive-title { color: white; font-family: serif; font-weight: bold; font-size: 1.2em; }
        .archive-green { color: #73d98c; }
        .cover-caption { color: alpha(white, 0.7); font-size: 0.8em; }
        .add-tile { border: 2px dashed alpha(currentColor, 0.4); border-radius: 6px; }
        .rank { font-weight: bold; opacity: 0.55; }
        .tile-title { font-weight: bold; }
        .ready { color: @success_color; }
        .waiting { color: @warning_color; }
        .banner-card { padding: 12px; border-radius: 10px; background-color: alpha(currentColor, 0.07); }
        .cover-well { border: 1.5px dashed alpha(currentColor, 0.35); border-radius: 6px; }
        .network-background, .canvas { background-color: alpha(currentColor, 0.04); }
        .canvas-float { background-color: alpha(@window_bg_color, 0.92); border-radius: 12px; padding: 6px;
                        box-shadow: 0 2px 6px alpha(black, 0.12); }
        .zoom-pill { border-radius: 99px; padding: 2px 8px; }
        .canvas-card { background-color: @window_bg_color; border-radius: 14px; padding: 10px;
                       border: 1px solid alpha(currentColor, 0.15); box-shadow: 0 2px 5px alpha(black, 0.10); }
        .canvas-card.selected { border: 2.5px solid @accent_bg_color; box-shadow: 0 2px 10px alpha(black, 0.18); }
        .canvas-card.problem { border-color: alpha(#ff7800, 0.8); }
        .clock-card { padding: 12px; }
        .clock-icon { color: @accent_color; background-color: alpha(@accent_bg_color, 0.12); border-radius: 28px;
                      min-width: 56px; min-height: 56px; }
        .remote-card { border: 1.5px dashed alpha(#21a19e, 0.8); }
        .remote-card.offline { border-color: alpha(currentColor, 0.4); opacity: 0.6; }
        .card-screen { background-color: black; border-radius: 6px; }
        .card-screen-frame { border-radius: 6px; border: 1px solid alpha(black, 0.4); }
        .card-off { color: alpha(white, 0.45); }
        .server-badge { font-size: 7pt; font-weight: bold; color: white; background-color: alpha(black, 0.55);
                        border-radius: 99px; padding: 2px 6px; }
        .station-badge { font-weight: bold; color: white; background-color: @accent_bg_color; border-radius: 6px;
                         min-width: 30px; min-height: 22px; padding: 0 3px; }
        .station-badge.small { min-width: 22px; min-height: 16px; font-size: 0.85em; }
        .station-badge.problem { background-color: #ff7800; }
        .state-dot.on { color: #2ec27e; }
        .state-dot.off { color: alpha(currentColor, 0.5); }
        .state-dot.suspended { color: #ff7800; }
        .state-dot.paused { color: #3584e4; }
        .state-dot.debugger { color: #e01b24; }
        .sending { color: #2ec27e; }
        .online-pill { padding: 1px 6px; border-radius: 99px; background-color: alpha(currentColor, 0.12); }
        .online-pill.on { background-color: alpha(#21a19e, 0.18); }
        .teal { color: #21a19e; }
        .warning { color: @warning_color; }
        .warning-card { padding: 12px; border-radius: 10px; background-color: alpha(#ff7800, 0.12); }
        .station-tile { background-color: @window_bg_color; border-radius: 10px; border: 1px solid alpha(currentColor, 0.2); }
        .station-tile.focused { border: 3px solid @accent_bg_color; }
        .focus-thumbnail { background-color: @window_bg_color; border-radius: 9px; padding: 6px;
                           border: 1px solid alpha(currentColor, 0.2); }
        .focus-thumbnail.showing { border: 2.5px solid @accent_bg_color; }
        .template-card { padding: 10px; border-radius: 12px; }
        .mandelbrot-backdrop { background-color: #1f1f1f; }
        .traffic-list row { padding: 1px 0; }
        .worker-0 { background-color: #ff7800; border-radius: 3px; }
        .worker-1 { background-color: #2ec27e; border-radius: 3px; }
        .worker-2 { background-color: #f26699; border-radius: 3px; }
        .worker-3 { background-color: #9141ac; border-radius: 3px; }
        .worker-4 { background-color: #21a19e; border-radius: 3px; }
        .worker-5 { background-color: #e01b24; border-radius: 3px; }
        .worker-6 { background-color: #f6d32d; border-radius: 3px; }
        .worker-7 { background-color: #66d9b3; border-radius: 3px; }
        .worker-8 { background-color: #4d4dbf; border-radius: 3px; }
        .worker-9 { background-color: #99734d; border-radius: 3px; }
        .command-block { font-family: monospace; padding: 8px; border-radius: 6px;
                         background-color: alpha(currentColor, 0.06); }
        """
}

/// What LinuxArch shows when it opens (Preferences ▸ General), as MacArch's
/// opening screen. (LinuxArch has no welcome screen: a machine window
/// without a ROM is its setup page.)
enum LaunchScreen: String, CaseIterable {
    case machine, games, network

    static let defaultsKey = "launchScreen"

    var title: String {
        switch self {
        case .machine: "An Archimedes"
        case .games: "The Game Library"
        case .network: "The Network Studio"
        }
    }

    @MainActor
    static var preference: LaunchScreen {
        get { Preferences.standard.string(forKey: defaultsKey).flatMap(LaunchScreen.init(rawValue:)) ?? .machine }
        set { Preferences.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// What this launch shows: the setting as it was when the app started.
    /// Self-tests need a machine.
    @MainActor
    static let atLaunch: LaunchScreen = AppSettings.isSelfTest ? .machine : preference
}

/// About the app.
enum AppInfo {
    static let id = "com.accidentalfish.LinuxArch"
    static let version = "0.5.0"
    /// MacArch's, which LinuxArch is.
    static let repository = "https://github.com/acorn-playground/macarch"
    static let website = "https://jamesdrandall.com"
}

/// Where the app keeps its files, and where its own come from.
enum AppPaths {
    /// The real executable, through any symlinks.
    static var executable: URL {
        URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
    }

    /// The source tree's Apps folder, for `swift run`.
    private static let sourceApps = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../..").standardized

    /// `PREFIX/share/linuxarch` for the app installed in PREFIX/bin or
    /// PREFIX/lib/linuxarch; in the source tree, the Mac app's Resources
    /// (which the two share). LINUXARCH_RESOURCES gives another.
    static var resources: URL? {
        if let path = ProcessInfo.processInfo.environment["LINUXARCH_RESOURCES"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let directory = executable.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("../share/linuxarch"),
            directory.appendingPathComponent("../../share/linuxarch"),
            sourceApps.appendingPathComponent("MacArch/Resources"),
        ].map(\.standardized)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A bundled file, if it's there.
    static func resource(_ path: String) -> URL? {
        guard let url = resources?.appendingPathComponent(path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// LinuxArch's release notes: installed, or in the source tree.
    static var whatsNew: URL? {
        resource("WHATSNEW.md") ?? [sourceApps.appendingPathComponent("LinuxArch/WHATSNEW.md")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The folder of icon themes with the app's icon: PREFIX/share/icons
    /// (which the desktop may not search, for an unusual PREFIX), or the
    /// source tree's, for `swift run`.
    static var icons: URL? {
        let installed = resource("WHATSNEW.md").map { $0.deletingLastPathComponent().appendingPathComponent("../icons").standardized }
        return [installed, sourceApps.appendingPathComponent("LinuxArch/data/icons")].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("hicolor/scalable/apps/\(AppInfo.id).svg").path)
        }
    }

    /// macarch-mcp: beside the app.
    static var mcpServer: URL {
        executable.deletingLastPathComponent().appendingPathComponent("macarch-mcp")
    }

    /// `$XDG_DATA_HOME`, or ~/.local/share.
    nonisolated static var dataHome: URL {
        ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    }
}
