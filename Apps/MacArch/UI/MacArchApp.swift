import AppKit
import ArchimedesCore
import SwiftUI

@main
struct MacArchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(MachineController.self) private var machine

    var body: some Scene {
        WindowGroup("Archimedes", id: MachineWindow.windowID) {
            MachineWindow()
        }
        // Only when Settings ▸ General says to open with an Archimedes
        // (otherwise it's the welcome screen or another part).
        .defaultLaunchBehavior(LaunchScreen.atLaunch == .machine ? .automatic : .suppressed)
        .restorationBehavior(LaunchScreen.atLaunch == .machine ? .automatic : .disabled)
        .defaultSize(width: 960, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacArch") { AboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                    .disabled(!Updates.shared.isAvailable)
            }
            CommandGroup(after: .appSettings) { ROMsMenuItem() }
            CommandGroup(replacing: .help) { WhatsNewMenuItem() }
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { machine?.openDisc() }
                    .keyboardShortcut("o")
                    .disabled(machine?.host == nil)
                RecentDiscsMenu(machine: machine)
                Divider()
                Button("Save Disc Changes") { machine?.saveDisc() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(!(machine?.disc.modified ?? false) || !(machine?.disc.savable ?? false))
                Button("Save Disc As…") { machine?.saveDiscAs() }
                    .disabled(machine?.discName == nil || !(machine?.disc.savable ?? false))
                Button("Eject Disc") { machine?.ejectDisc() }
                    .keyboardShortcut("e")
                    .disabled(machine?.discName == nil)
                Divider()
                HardDiscMenus(machine: machine)
                Divider()
                NetworkMenuItems()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Screenshot…") { machine?.saveScreenshot() }
                    .keyboardShortcut("s")
                    .disabled(machine?.host == nil)
                Divider()
                Button("Save State…") { machine?.saveState() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(machine?.host == nil)
                Button("Load State…") { machine?.loadState() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(machine?.host == nil)
                Button("Quick Save") { machine?.quickSave() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(machine?.host == nil)
                Button("Quick Load") { machine?.quickLoad() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(machine?.host == nil)
                Divider()
                Button(machine?.recordingURL == nil ? "Start Recording…" : "Stop Recording") { machine?.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(machine?.host == nil)
            }
            CommandGroup(replacing: .pasteboard) {
                // In a text field (joining a network, settings, names),
                // the usual editing; at an Archimedes, copy its screen and
                // paste text into it.
                Button("Cut") { TextEditing.send(#selector(NSText.cut(_:))) }
                    .keyboardShortcut("x")
                Button("Copy") {
                    if TextEditing.active { TextEditing.send(#selector(NSText.copy(_:))) } else { machine?.copyScreenshot() }
                }
                .keyboardShortcut("c")
                Button("Paste") {
                    if TextEditing.active { TextEditing.send(#selector(NSText.paste(_:))) } else { machine?.pasteText() }
                }
                .keyboardShortcut("v")
                Button("Select All") { TextEditing.send(#selector(NSText.selectAll(_:))) }
                    .keyboardShortcut("a")
                Divider()
                Button("Copy Screenshot") { machine?.copyScreenshot() }
                    .disabled(machine?.host == nil)
                Button("Paste Text into Archimedes") { machine?.pasteText() }
                    .disabled(machine?.host == nil)
            }
            CommandGroup(after: .toolbar) {
                Picker("Display", selection: Binding(
                    get: { machine?.displayStyle ?? DisplayStyle.saved },
                    set: { machine?.displayStyle = $0 }
                )) {
                    ForEach(DisplayStyle.allCases) { Text($0.name).tag($0) }
                }
                .disabled(machine == nil)
                Menu("Zoom") {
                    ForEach(MachineController.zoomLevels, id: \.self) { level in
                        Toggle("\(Int(level * 100))%", isOn: Binding(get: { machine?.zoom == level },
                                                                    set: { _ in machine?.setZoom(level) }))
                    }
                }
                .disabled(machine?.host == nil)
                Button("Actual Size") { machine?.setZoom(1) }
                    .keyboardShortcut("0")
                    .disabled(machine?.host == nil)
                Button("Zoom In") { machine?.zoom(in: true) }
                    .keyboardShortcut("=")
                    .disabled(machine?.host == nil)
                Button("Zoom Out") { machine?.zoom(in: false) }
                    .keyboardShortcut("-")
                    .disabled(machine?.host == nil)
                Divider()
            }
            CommandMenu("Debug") {
                Button("Show Debugger") { machine?.debuggerRequested = true }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(machine?.host == nil)
                Button(machine?.debugStop == nil ? "Break into Debugger" : "Continue") {
                    if let machine {
                        machine.debugger.pauseOrContinue()
                        // Breaking in opens the debugger.
                        machine.debuggerRequested = machine.debugStop == nil
                    }
                }
                .keyboardShortcut("y", modifiers: [.command, .control])
                .disabled(machine?.host == nil)
            }
            CommandMenu("MCP") { MCPMenu() }
            CommandGroup(after: .windowSize) {
                Button("Make 16:9") { machine?.makeWidescreen() }
                    .disabled(machine?.host == nil)
            }
            CommandGroup(before: .windowList) {
                WelcomeMenuItem()
                GameLibraryMenuItem()
                NetworkStudioMenuItem()
                Divider()
            }
            CommandMenu("Machine") {
                ImportMachineConfigurationButton(machine: machine)
                Divider()
                Group {
                Button(machine?.paused == true || machine?.heldForAgent == true ? "Resume" : "Pause") { machine?.togglePause() }
                    .keyboardShortcut("p")
                Button(machine?.speedLimited == false ? "Normal Speed" : "Full Speed") { machine?.toggleSpeedLimit() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Toggle("Mute", isOn: Binding(get: { machine?.muted ?? false }, set: { machine?.muted = $0 }))
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                Button("Reset") { machine?.reset() }
                    .keyboardShortcut("b")
                Button("Power Cycle") { machine?.powerCycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Capture or Release Mouse") { machine?.toggleMouseCapture() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                Divider()
                Button("Rewind 5 Seconds") { machine?.rewind(seconds: 5) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Rewind Timeline…") { machine?.showingTimeline = true }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                Divider()
                // A Classic on several discs: the next one, when it asks.
                Button(machine?.nextSessionDiscTitle ?? "Next Disc") { machine?.insertNextSessionDisc() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(machine?.sessionDiscsActive != true)
                Divider()
                HardwarePickers(machine: machine)
                }
                .disabled(machine?.host == nil)
            }
        }

        WindowGroup("Archimedes", id: MachineConfigurationCommands.windowID, for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                MachineWindow(machine: machine)
            } else {
                ClosesItself()
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 960, height: 760)

        WindowGroup("Network", id: NetworkStudioWindow.windowID, for: URL.self) { $url in
            NetworkStudioWindow(url: url)
        }
        .defaultSize(width: 1180, height: 780)

        WindowGroup("Station", id: StationWindow.windowID, for: StationWindow.Ref.self) { $ref in
            StationWindow(ref: ref)
        }
        .defaultSize(width: 800, height: 640)
        .restorationBehavior(.disabled)

        Window(GameLibraryView.title, id: GameLibraryView.windowID) { GameLibraryView() }
            .defaultSize(width: 980, height: 720)
            .defaultLaunchBehavior(LaunchScreen.atLaunch == .games ? .presented : .suppressed)
        Window(WelcomeScreen.title, id: WelcomeScreen.windowID) { WelcomeScreen() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            // The welcome screen, or on its way to the Network Studio.
            .defaultLaunchBehavior(LaunchScreen.atLaunch == .welcome || LaunchScreen.atLaunch == .network ? .presented : .suppressed)
        Window("New Network", id: NetworkStartView.windowID) { NetworkStartView() }
            .windowResizability(.contentSize)
        Window("Join Econet Network", id: JoinRoomView.windowID) { JoinRoomView() }
            .windowResizability(.contentSize)

        WindowGroup("Debugger", id: "debugger", for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                DebuggerWindow(model: machine.debugger)
                    .navigationTitle("Debugger — \(machine.machineName)")
            } else {
                ClosesItself()
            }
        }
        .defaultSize(width: 1100, height: 760)

        WindowGroup("Configure Machine", id: "configure", for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                ConfigureMachineWindow(machine: machine)
                    .navigationTitle("Configure — \(machine.machineName)")
            } else {
                ClosesItself()
            }
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentSize)

        Window("ROMs", id: "roms") { ROMsWindowView() }
            .defaultSize(width: 560, height: 560)
        Window("Connect an AI Agent", id: "mcp-setup") { MCPSetupView() }
            .windowResizability(.contentSize)
        Window("MCP Activity", id: "mcp-log") { AgentLogView() }
            .defaultSize(width: 900, height: 560)
        Window("What's New", id: "whats-new") { WhatsNewView() }
            .defaultSize(width: 520, height: 520)

        Settings {
            SettingsView()
        }
    }
}

/// MacArch > ROMs…: always available, even before a machine is running.
struct ROMsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ROMs…") { openWindow(id: "roms") }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])
    }
}

/// MCP > Connect an AI Agent…, Activity Log.
struct MCPMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connect an AI Agent…") { openWindow(id: "mcp-setup") }
        Button("Activity Log") { openWindow(id: "mcp-log") }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

/// The model, processor, memory, monitor and ROM (each power cycles the machine).
struct HardwarePickers: View {
    let machine: MachineController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = machine?.model ?? .a3000
        Button("Configure Machine…") { if let machine { openWindow(id: "configure", value: machine.id) } }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Divider()
        Button("Export Machine Configuration…") { machine?.chooseExportConfiguration() }
            .disabled(machine?.host == nil || machine?.isStation == true)
        Divider()
        Picker("Model", selection: Binding(get: { model }, set: { machine?.setHardware(model: $0) })) {
            ForEach(MachineModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Picker("Processor", selection: Binding(get: { machine?.cpu ?? .arm2 }, set: { machine?.setHardware(cpu: $0) })) {
            ForEach(CPUType.allCases, id: \.self) { cpu in
                Text(cpu.displayName).tag(cpu)
                    .disabled(!model.cpuChoices.contains(cpu))
            }
        }
        Picker("Memory", selection: Binding(get: { machine?.ramKB ?? model.defaultRAMKB }, set: { machine?.setHardware(ramKB: $0) })) {
            ForEach(model.ramChoices, id: \.self) { Text(AppSettings.ramLabel($0)).tag($0) }
        }
        Picker("Monitor", selection: Binding(get: { machine?.monitor ?? .standard }, set: { machine?.setHardware(monitor: $0) })) {
            ForEach(MonitorType.allCases, id: \.self) { t in
                Text(t.displayName).tag(t)
                    .disabled(!model.monitorChoices.contains(t))
            }
        }
        // A button inside a Picker is taken for one of its choices (and
        // does nothing), so the picker and Add ROMs… share a submenu.
        Menu("ROM") {
            Picker("ROM", selection: Binding(get: { machine?.romPath ?? "" }, set: { machine?.setHardware(romPath: $0) })) {
                ForEach(AppSettings.shared.romLibrary) { Text($0.version).tag($0.path) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Add ROMs…") { openWindow(id: "roms") }
        }
    }
}

/// New, open and remove for each hard disc drive (400 series only).
struct HardDiscMenus: View {
    let machine: MachineController?

    var body: some View {
        Menu("Hard Disc") { HardDiscItems(machine: machine) }
            .disabled((machine?.model.hardDiscSlots ?? 0) == 0 || machine?.host == nil)
            .help("The 400 series (ST506) and the A5000, A3020 and A4000 (IDE) take hard discs; changing a drive power cycles the machine")
    }
}

/// Open Recent, for the File menu and the toolbar's disc button. A view of
/// its own so it redraws when the list changes (toolbar content doesn't
/// track what it reads).
struct RecentDiscsMenu: View {
    let machine: MachineController?

    var body: some View {
        let recents = AppSettings.shared.recentDiscs
        Menu("Open Recent") {
            ForEach(recents, id: \.self) { path in
                Button((path as NSString).lastPathComponent) { machine?.insertDisc(URL(fileURLWithPath: path)) }
            }
            Divider()
            Button("Clear Menu") { AppSettings.shared.clearRecents() }
                .disabled(recents.isEmpty)
        }
        .disabled(machine?.host == nil)
    }
}

struct HardDiscItems: View {
    let machine: MachineController?

    var body: some View {
        let slots = machine?.model.hardDiscSlots ?? 0
            ForEach(0..<max(slots, 1), id: \.self) { drive in
                Section("Drive :\(drive + 4)" + (machine?.hardDiscName(drive).map { " — \($0)" } ?? "")) {
                    Button("New Hard Disc…") { machine?.newHardDisc(drive: drive) }
                    Button("New Hard Disc from Files…") { machine?.newHardDiscFromFiles(drive: drive) }
                    Button("Add Files to Hard Disc…") { machine?.addFilesToHardDisc(drive: drive) }
                        .disabled(machine?.hardDiscName(drive) == nil)
                    Button("Resize Hard Disc…") { machine?.resizeHardDisc(drive: drive) }
                        .disabled(machine?.hardDiscName(drive) == nil)
                    Button("Open Hard Disc…") { machine?.openHardDisc(drive: drive) }
                    Button("Remove Hard Disc") { machine?.ejectHardDisc(drive: drive) }
                        .disabled(machine?.hardDiscName(drive) == nil)
                }
            }
    }
}

struct MachineWindow: View {
    static let windowID = "machine"
    @State private var machine: MachineController

    @MainActor init(machine: MachineController? = nil) {
        _machine = State(initialValue: machine ?? MachineController())
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var active

    var body: some View {
        MachineScreen(machine: machine)
            .onAppear {
                if WhatsNew.shouldShowOnLaunch() { openWindow(id: "whats-new") }
                MachineController.frontmost = machine
                // A game the Game Library asked for, with no machine open.
                if let launch = MachineController.pendingLaunch {
                    MachineController.pendingLaunch = nil
                    launch(machine)
                }
            }
            .onChange(of: active) { if active == .key { MachineController.frontmost = machine } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                machine.shutdown()
            }
            // Agents and the self-test ask for networks' windows.
            .onReceive(NotificationCenter.default.publisher(for: NetworkStudioCommands.openRequest)) { note in
                if let url = note.object as? URL { NetworkStudioCommands.open(url, openWindow: openWindow) }
            }
            .onReceive(NotificationCenter.default.publisher(for: LibrarySelfTest.openRequest)) { _ in
                openWindow(id: GameLibraryView.windowID)
            }
            .onReceive(NotificationCenter.default.publisher(for: WelcomeScreen.openRequest)) { _ in
                openWindow(id: WelcomeScreen.windowID)
            }
            // An invitation link (macarch://join…) from its web page.
            .onOpenURL { url in
                guard JoinRequests.isJoinLink(url) else { return }
                JoinRequests.shared.handle(url)
                openWindow(id: JoinRoomView.windowID)
            }
    }
}

/// A machine's window: its picture, toolbar and menus. A standalone
/// machine's, or a network station's in its own window.
struct MachineScreen: View {
    @Bindable var machine: MachineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let host = machine.host {
                EmulatorView(machine: machine, host: host, style: machine.displayStyle,
                             onRenderer: { machine.renderer = $0 }, onZoom: { machine.pictureZoomed($0) })
                    .frame(minWidth: 416, minHeight: 288)
                    .background(.black)
                    .toolbar(id: "machine") { MachineToolbar(machine: machine) }
                    .toolbarRole(.editor)
                    .overlay(alignment: .bottomLeading) {
                        if let text = machine.inspection, !text.isEmpty {
                            Text(text)
                                .font(.system(.callout, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                WelcomeView(machine: machine)
            }
        }
        .focusedSceneValue(machine)
        .navigationTitle(machine.title)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // Several archives or folders at once: files for a hard disc.
            if urls.count > 1, machine.host != nil, urls.allSatisfy({ $0.pathExtension.lowercased() == "zip" || $0.hasDirectoryPath }) {
                machine.offerFilesForHardDisc(urls)
                return true
            }
            if url.pathExtension.lowercased() == NetworkPackage.fileExtension {
                NetworkStudioCommands.open(url, openWindow: openWindow)
                return true
            }
            return machine.open(url)
        }
        .onOpenURL { url in
            if JoinRequests.isJoinLink(url) { return } // (the window's own handler joins)
            if url.pathExtension.lowercased() == NetworkPackage.fileExtension {
                NetworkStudioCommands.open(url, openWindow: openWindow)
            } else {
                _ = machine.open(url)
            }
        }
        .sheet(isPresented: $machine.showingTimeline) { RewindSheet(machine: machine) }
        .onChange(of: machine.debuggerRequested) {
            if machine.debuggerRequested {
                machine.debuggerRequested = false
                openWindow(id: "debugger", value: machine.id)
            }
        }
        .onChange(of: machine.configureRequested) {
            if machine.configureRequested {
                machine.configureRequested = false
                openWindow(id: "configure", value: machine.id)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a plain executable rather than an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Starts the background update checks.
        _ = Updates.shared
        WelcomeReturn.start()
    }

    /// With the welcome screen as the opening screen, closing the last
    /// window brings it back (WelcomeReturn), and closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !WelcomeReturn.applies }

    /// The Dock icon clicked with no windows open: the welcome screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && WelcomeReturn.applies {
            WelcomeReturn.open()
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MachineController.confirmQuit() ? .terminateNow : .terminateCancel
    }
}

/// A window restored at launch for a machine window that no longer exists
/// (they're per machine, by id): it closes rather than standing empty.
struct ClosesItself: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { dismiss() }
    }
}

/// Standard text editing for the field with the keyboard, when there is one.
enum TextEditing {
    static var active: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// Sends an editing action down the responder chain.
    static func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
