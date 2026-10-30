import ArchimedesCore
import CGtk
import Foundation

/// An Archimedes' window: the screen, a header bar with the common actions
/// and the machine's lights, and a main menu with everything else (the Mac
/// app's window, toolbar and menu bar). Before there's a ROM to switch on
/// with, it shows a page for adding one.
@MainActor
final class MachineWindow {
    /// Open windows, newest last.
    static var all: [MachineWindow] = []

    let window: Widget
    let machine: MachineController
    let emulator: EmulatorView
    private var actions: Actions!
    private let windowTitle: OpaquePointer
    private let toolbarView: Widget
    private let stack: Widget
    private let errorLabel: Widget
    private let inspectionLabel: Widget
    private var debuggerWindow: DebuggerWindow?
    private var discContentsWindow: DiscContentsWindow?
    private let toastOverlay: Widget
    private var setupPage: SetupPage!
    private var rewindDialog: RewindDialog?
    private var configureDialog: ConfigureMachineDialog?
    private let recentMenu = Menu()
    private let romMenu = Menu()
    private let processorMenu = Menu()
    private let memoryMenu = Menu()
    private let monitorMenu = Menu()
    private let hardDiscMenu = Menu()
    /// Items whose labels follow the machine.
    private let pauseSection = Menu()
    private let recordSection = Menu()
    private let debugSection = Menu()
    private let nextDiscSection = Menu()
    private let recentNetworksMenu = Menu()
    private var mouseCaptured = false
    private var closing = false
    /// The header bar's buttons that only make sense with a machine running.
    private var machineButtons: [Widget] = []
    private var hardDiscButton: Widget?

    /// A standalone machine's window, or (given its controller) a network
    /// station's, which leaves the station running when it closes.
    init(app: OpaquePointer, machine station: MachineController? = nil) {
        machine = station ?? MachineController()
        emulator = EmulatorView()
        window = adw_application_window_new(app.cast())!
        // The usual 832 x 576 picture, at this width, under the header bar.
        gtk_window_set_default_size(window.cast(), 960, 712)
        windowTitle = OpaquePointer(adw_window_title_new("LinuxArch", "")!)
        toolbarView = adw_toolbar_view_new()!
        stack = gtk_stack_new()!
        errorLabel = UI.label("", classes: ["picture-error"], wrap: true, xalign: 0.5)
        inspectionLabel = UI.label("", classes: ["inspection", "monospace"])
        toastOverlay = adw_toast_overlay_new()!
        machine.window = self
        emulator.machine = machine
        emulator.style = machine.displayStyle
        emulator.border = machine.displayBorder
        emulator.onZoom = { [weak machine] zoom in machine?.pictureZoomed(zoom) }
        emulator.onMouseCapture = { [weak self] captured in
            self?.mouseCaptured = captured
            self?.updateTitle()
        }

        actions = Actions(window)
        addActions()
        buildContent()
        acceptFileDrops(on: window) { [weak self] urls in
            guard let self else { return false }
            for url in urls { self.machine.open(url) }
            return true
        }
        observeMachine()

        onSignalReturning(window, "close-request") { [weak self] in
            guard let self else { return false }
            if self.closing { return false }
            // A station runs on: nothing's lost, so it just closes.
            if self.machine.isStation {
                self.closing = true
                self.tidyUp()
                return false
            }
            Task { @MainActor in
                guard await self.machine.confirmDiscChanges(before: "closing the window") else { return }
                self.forceClose()
            }
            return true
        }
        onNotify(window, "is-active") { [weak self] in
            guard let self else { return }
            if gtk_window_is_active(self.window.cast()) != 0 {
                // (Games play in a standalone machine.)
                if !self.machine.isStation { MachineController.frontmost = self.machine }
                ClassicsLibrary.shared.appBecameActive()
            } else {
                self.emulator.focusLost()
            }
        }
        Self.all.append(self)
        guard !machine.isStation else { return }

        // A new window switches straight on, with the ROM last used.
        if let rom = AppSettings.shared.romPath {
            machine.start(romPath: rom)
        }
        MachineController.frontmost = machine
        // A game the Game Library asked for, with no machine open.
        if machine.host != nil, let launch = MachineController.pendingLaunch {
            MachineController.pendingLaunch = nil
            after(0) { [weak self] in
                guard let self else { return }
                launch(self.machine)
            }
        }
    }

    func present() {
        gtk_window_present(window.cast())
        emulator.grabFocus()
    }

    /// Closes without asking (the question's been asked).
    func forceClose() {
        guard !closing else { return }
        closing = true
        tidyUp()
        gtk_window_close(window.cast())
    }

    /// The window's going: its other windows close, and its machine stops
    /// (a network's station runs on).
    private func tidyUp() {
        rewindDialog?.close()
        configureDialog?.close()
        debuggerWindow?.close()
        discContentsWindow?.close()
        if machine.isStation {
            // Its network runs it on; another window may show it later.
            emulator.setMouseCaptured(false)
            if machine.window === self { machine.window = nil }
        } else {
            machine.shutdown()
        }
        Self.all.removeAll { $0 === self }
    }

    // MARK: Content

    private func buildContent() {
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(header.cast(), windowTitle.widget)

        // Start: the machine, the games, the disc, the hard discs, Reset, Power.
        let modelButton = menuButton(icon: "computer-symbolic", tooltip: "Choose the machine (power cycles)", menu: modelMenu())
        let gamesButton = UI.actionButton(icon: "applications-games-symbolic",
                                          tooltip: "The Game Library: the Archimedes Classics from the Archimedes Archive, and your own games",
                                          action: "app.game-library")
        let discButton = splitButton(icon: "media-floppy-symbolic", tooltip: "Open a disc", action: "win.open-disc",
                                     menu: discMenu())
        let hardDisc = menuButton(icon: "drive-harddisk-symbolic", tooltip: "Hard discs (changing a drive power cycles the machine)",
                                  menu: hardDiscMenu)
        hardDiscButton = hardDisc
        let resetButton = UI.actionButton(icon: "view-refresh-symbolic", tooltip: "Reset", action: "win.reset")
        let powerButton = UI.actionButton(icon: "system-shutdown-symbolic", tooltip: "Switch off and on again",
                                          action: "win.power-cycle")
        for button in [modelButton, gamesButton, discButton, hardDisc, resetButton, powerButton] {
            adw_header_bar_pack_start(header.cast(), button)
        }

        // End (right to left): the main menu, the lights, then the rest.
        let mainMenu = menuButton(icon: "open-menu-symbolic", tooltip: "Main Menu", menu: self.mainMenu())
        // (Not the primary menu, which F10 would open: F10 is the Archimedes'.)
        gtk_menu_button_set_primary(mainMenu.cast(), 0)
        adw_header_bar_pack_end(header.cast(), mainMenu)
        let lights = lightsWidget()
        adw_header_bar_pack_end(header.cast(), lights)
        let rewind = splitButton(icon: "media-seek-backward-symbolic", tooltip: "Go back 5 seconds",
                                 action: "win.rewind", target: "5", menu: rewindMenu())
        let pause = gtk_toggle_button_new()!
        gtk_button_set_icon_name(pause.cast(), "media-playback-pause-symbolic")
        gtk_actionable_set_action_name(pause.cast(), "win.pause")
        let record = gtk_toggle_button_new()!
        gtk_button_set_icon_name(record.cast(), "media-record-symbolic")
        gtk_actionable_set_action_name(record.cast(), "win.record")
        let screenshot = UI.actionButton(icon: "camera-photo-symbolic", tooltip: "Save a screenshot", action: "win.screenshot")
        for button in [screenshot, record, pause, rewind].reversed() {
            adw_header_bar_pack_end(header.cast(), button)
        }
        machineButtons = [modelButton, discButton, hardDisc, resetButton, powerButton, rewind, pause, record, screenshot, lights]
        // A narrow window has room for fewer buttons; the rest are in the
        // main menu.
        // (Not the hard disc button, which the model shows or hides: a
        // breakpoint puts back what it found.)
        addBreakpoint("max-width: 800sp", hiding: [screenshot, record, powerButton])
        addBreakpoint("max-width: 620sp", hiding: [screenshot, record, powerButton, resetButton, lights, modelButton, gamesButton])
        observe(self) { [weak self] in
            guard let self else { return }
            let machine = self.machine
            gtk_button_set_icon_name(pause.cast(), machine.isStill ? "media-playback-start-symbolic" : "media-playback-pause-symbolic")
            pause.setTooltip(machine.heldForAgent && !machine.paused
                             ? "Resume (an AI agent is holding the machine between its tool calls)"
                             : machine.paused ? "Resume" : "Pause")
            record.setTooltip(machine.recordingURL == nil ? "Record a video" : "Stop recording")
            record.setClass("recording", machine.recordingURL != nil)
        }

        // The screen, with the debugger's inspection and any error over it.
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(overlay.cast(), emulator.area)
        inspectionLabel.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_END)
        inspectionLabel.setMargins(8)
        gtk_widget_set_can_target(inspectionLabel, 0)
        inspectionLabel.setVisible(false)
        gtk_overlay_add_overlay(overlay.cast(), inspectionLabel)
        errorLabel.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        errorLabel.setVisible(false)
        gtk_overlay_add_overlay(overlay.cast(), errorLabel)
        overlay.addClass("emulator-background")
        // Toasts ("Saved", "Loaded") over the screen.
        adw_toast_overlay_set_child(toastOverlay.cast(), overlay)

        setupPage = SetupPage(machine: machine)
        gtk_stack_add_named(stack.cast(), setupPage.widget, "setup")
        gtk_stack_add_named(stack.cast(), toastOverlay, "machine")
        gtk_stack_set_transition_type(stack.cast(), GTK_STACK_TRANSITION_TYPE_CROSSFADE)

        adw_toolbar_view_add_top_bar(toolbarView.cast(), header)
        adw_toolbar_view_set_content(toolbarView.cast(), stack)
        adw_application_window_set_content(window.cast(), toolbarView)

        onSignal(emulator.area, "realize", after: true) { [weak self] in
            guard let self, let error = self.emulator.rendererError else { return }
            UI.setText(self.errorLabel, "The picture can’t be shown: OpenGL failed.\n\n\(error)")
            self.errorLabel.setVisible(true)
        }
    }

    private func addBreakpoint(_ condition: String, hiding widgets: [Widget]) {
        let breakpoint = adw_breakpoint_new(adw_breakpoint_condition_parse(condition))!
        for widget in widgets {
            la_breakpoint_hide(breakpoint, widget)
        }
        adw_application_window_add_breakpoint(window.cast(), breakpoint)
    }

    private func menuButton(icon: String, tooltip: String, menu: Menu) -> Widget {
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(button.cast(), icon)
        gtk_menu_button_set_menu_model(button.cast(), menu.model)
        button.setTooltip(tooltip)
        return button
    }

    private func splitButton(icon: String, tooltip: String, action: String, target: String? = nil, menu: Menu) -> Widget {
        let button = adw_split_button_new()!
        adw_split_button_set_icon_name(button.cast(), icon)
        adw_split_button_set_menu_model(button.cast(), menu.model)
        if let target {
            gtk_actionable_set_action_target_value(button.cast(), g_variant_new_string(target))
        }
        gtk_actionable_set_action_name(button.cast(), action)
        button.setTooltip(tooltip)
        return button
    }

    /// The keyboard's Caps, Num and Scroll Lock lights, the floppy drive's,
    /// and the AI agent's light while one's attached.
    private func lightsWidget() -> Widget {
        func light(_ label: String, _ colour: String) -> (Widget, Widget) {
            let dot = UI.box(GTK_ORIENTATION_HORIZONTAL, classes: ["light", colour])
            dot.align(horizontal: GTK_ALIGN_CENTER)
            let column = UI.vbox(spacing: 2, [dot, UI.label(label, classes: ["light-label"], xalign: 0.5)])
            return (column, dot)
        }
        let caps = light("CAPS", "green"), num = light("NUM", "green"), scroll = light("SCROLL", "green")
        let drive = light("DISC", "orange")
        let agent = light("MCP", "agent")
        let agentButton = gtk_button_new()!
        gtk_button_set_child(agentButton.cast(), agent.0)
        agentButton.addClass("flat")
        agentButton.addClass("agent-light")
        gtk_actionable_set_action_name(agentButton.cast(), "app.mcp-log")
        let lights = UI.hbox(spacing: 7, [caps.0, num.0, scroll.0, drive.0])
        lights.setTooltip("Caps Lock, Num Lock, Scroll Lock and the floppy drive")
        let box = UI.hbox(spacing: 4, [agentButton, lights], classes: ["lights"])
        box.align(vertical: GTK_ALIGN_CENTER)
        let log = AgentLog.shared
        observe(self) { [weak self] in
            guard let self else { return }
            let lit = self.machine.lights
            caps.1.setClass("on", lit.capsLock)
            num.1.setClass("on", lit.numLock)
            scroll.1.setClass("on", lit.scrollLock)
            drive.1.setClass("on", lit.drive)
            let attached = self.machine.servesAgents && log.connections > 0
            agentButton.setVisible(attached)
            agent.1.setClass("on", attached)
            agent.1.setClass("busy", log.callsRunning > 0)
            agentButton.setTooltip(log.connections == 1 ? "An AI agent is attached (click for the activity log)"
                                   : "\(log.connections) AI agents are attached (click for the activity log)")
        }
        return box
    }

    // MARK: Menus

    private func modelMenu() -> Menu {
        Menu()
            .section("Model") { section in
                for model in MachineModel.allCases {
                    section.item(model.displayName, "win.model", string: model.rawValue)
                }
            }
            .section { $0.item("Configure Machine…", "win.configure") }
    }

    private func discMenu() -> Menu {
        let menu = Menu()
        menu.section { section in
            section.item("Open Disc…", "win.open-disc")
            if !AppSettings.bundledArcLibre(withExtension: "adf").isEmpty {
                section.item("Insert ArcLibre Extras Disc", "win.arclibre-extras")
            }
            section.submenu("Open Recent") { submenu in
                g_menu_append_section(submenu.pointer, nil, recentMenu.model)
                submenu.section { $0.item("Clear Menu", "win.clear-recent") }
            }
            section.submenu("New Disc") { submenu in
                for format in ADFSFloppyFormatter.Format.allCases {
                    submenu.item(format.name, "win.new-disc", string: format.rawValue)
                }
            }
            section.item("Show Disc Contents", "win.disc-contents", string: "floppy")
        }
        menu.section { section in
            section.item("Save Disc Changes", "win.save-disc")
            section.item("Save Disc As…", "win.save-disc-as")
            section.item("Eject Disc", "win.eject-disc")
        }
        return menu
    }

    private func rewindMenu() -> Menu {
        Menu()
            .section { section in
                section.item("Back 1 Second", "win.rewind", string: "1")
                section.item("Back 5 Seconds", "win.rewind", string: "5")
                section.item("Back 30 Seconds", "win.rewind", string: "30")
            }
            .section { $0.item("Timeline…", "win.timeline") }
    }

    /// Everything, as the Mac app's menu bar has it.
    private func mainMenu() -> Menu {
        let menu = Menu()
        menu.section { section in
            section.item("Game Library", "app.game-library")
            section.item("Network Studio", "app.network-studio")
            section.item("New Archimedes Window", "app.new-window")
        }
        menu.section { section in
            section.submenu("Disc") { submenu in
                g_menu_append_section(submenu.pointer, nil, discMenu().model)
            }
            g_menu_append_submenu(section.pointer, "Hard Disc", hardDiscMenu.model)
        }
        menu.section { section in
            section.item("Save Screenshot…", "win.screenshot")
            section.item("Copy Screenshot", "win.copy-screenshot")
            section.item("Paste Text into Archimedes", "win.paste-text")
            g_menu_append_section(section.pointer, nil, recordSection.model)
        }
        menu.section { section in
            section.item("Save State…", "win.save-state")
            section.item("Load State…", "win.load-state")
            section.item("Quick Save", "win.quick-save")
            section.item("Quick Load", "win.quick-load")
        }
        menu.section { submenus in
            submenus.submenu("Machine") { submenu in
                g_menu_append_section(submenu.pointer, nil, pauseSection.model)
                submenu.section { section in
                    section.item("Full Speed", "win.full-speed")
                    section.item("Mute", "win.mute")
                    section.item("Disc Drive Sounds", "win.disc-drive-sounds")
                }
                submenu.section { section in
                    section.item("Reset", "win.reset")
                    section.item("Power Cycle", "win.power-cycle")
                }
                submenu.section { section in
                    section.submenu("Mouse") { mouse in
                        for mode in AppSettings.MouseMode.allCases {
                            mouse.item(mode.name, "win.mouse-mode", string: mode.rawValue)
                        }
                    }
                    section.item("Capture or Release Mouse", "win.capture-mouse")
                }
                submenu.section { section in
                    section.item("Rewind 5 Seconds", "win.rewind", string: "5")
                    section.item("Rewind Timeline…", "win.timeline")
                }
                // A Classic on several discs: the next one, when it asks.
                g_menu_append_section(submenu.pointer, nil, nextDiscSection.model)
                submenu.section { section in
                    section.item("Configure Machine…", "win.configure")
                    section.submenu("Model") { models in
                        for model in MachineModel.allCases {
                            models.item(model.displayName, "win.model", string: model.rawValue)
                        }
                    }
                    g_menu_append_submenu(section.pointer, "Processor", processorMenu.model)
                    g_menu_append_submenu(section.pointer, "Memory", memoryMenu.model)
                    g_menu_append_submenu(section.pointer, "Monitor", monitorMenu.model)
                    g_menu_append_submenu(section.pointer, "ROM", romMenu.model)
                }
                submenu.section { section in
                    section.item("Import Machine Configuration…", "win.import-configuration")
                    section.item("Export Machine Configuration…", "win.export-configuration")
                }
            }
            submenus.submenu("View") { submenu in
                submenu.section("Display") { section in
                    for style in DisplayStyle.allCases {
                        section.item(style.name, "win.display-style", string: style.rawValue)
                    }
                }
                submenu.section("Border") { section in
                    for border in DisplayBorder.allCases {
                        section.item(border.name, "win.display-border", string: border.rawValue)
                    }
                }
                submenu.section("Zoom") { section in
                    for level in MachineController.zoomLevels {
                        section.item("\(Int(level * 100))%", "win.zoom", string: Self.zoomName(level))
                    }
                }
                submenu.section { section in
                    section.item("Actual Size", "win.actual-size")
                    section.item("Zoom In", "win.zoom-in")
                    section.item("Zoom Out", "win.zoom-out")
                    section.item("Make 16:9", "win.widescreen")
                    section.item("Fullscreen", "win.fullscreen")
                }
                submenu.section("Keyboard") { section in
                    for mode in KeyboardSettings.Mode.allCases {
                        section.item(mode.name, "win.keyboard-mode", string: mode.rawValue)
                    }
                }
            }
            submenus.submenu("Debug") { submenu in
                submenu.item("Show Debugger", "win.debugger")
                g_menu_append_section(submenu.pointer, nil, debugSection.model)
            }
            submenus.submenu("Network") { submenu in
                submenu.section { section in
                    section.item("New Network…", "app.network-new")
                    section.item("Open Network…", "app.network-open")
                    g_menu_append_submenu(section.pointer, "Open Recent Network", recentNetworksMenu.model)
                    section.item("Network Studio", "app.network-studio")
                }
                submenu.section { $0.item("Join Econet Network…", "app.network-join") }
            }
            submenus.submenu("AI Agents (MCP)") { submenu in
                submenu.item("Connect an AI Agent…", "app.mcp-setup")
                submenu.item("Activity Log", "app.mcp-log")
            }
        }
        menu.section { section in
            section.item("ROMs…", "app.roms")
            section.item("Preferences", "app.preferences")
            section.item("Keyboard Shortcuts", "app.shortcuts")
            section.item("What’s New in LinuxArch", "app.whats-new")
            section.item("About LinuxArch", "app.about")
        }
        return menu
    }

    static func zoomName(_ level: Double) -> String {
        String(Int(level * 100))
    }

    private func updateRecentMenu() {
        recentMenu.removeAll()
        for path in AppSettings.shared.recentDiscs {
            recentMenu.item((path as NSString).lastPathComponent, "win.open-recent", string: path)
        }
    }

    private func updateROMMenu() {
        romMenu.removeAll()
        romMenu.section { section in
            for rom in AppSettings.shared.romLibrary {
                section.item(AppSettings.shared.label(rom), "win.rom", string: rom.path)
            }
        }
        romMenu.section { $0.item("Add ROMs…", "win.add-roms") }
    }

    /// The choices the model has (others can't be fitted).
    private func updateHardwareMenus() {
        let model = machine.model
        processorMenu.removeAll()
        for cpu in model.cpuChoices {
            processorMenu.item(cpu.displayName, "win.cpu", string: cpu.rawValue)
        }
        memoryMenu.removeAll()
        for kb in model.ramChoices {
            memoryMenu.item(AppSettings.ramLabel(kb), "win.memory", string: String(kb))
        }
        monitorMenu.removeAll()
        for monitor in model.monitorChoices {
            monitorMenu.item(monitor.displayName, "win.monitor", string: monitor.rawValue)
        }
        hardDiscMenu.removeAll()
        guard model.hardDiscSlots > 0 else {
            hardDiscMenu.item("The \(model.displayName) has no hard disc", "win.none")
            return
        }
        for drive in 0..<model.hardDiscSlots {
            let name = machine.hardDiscName(drive)
            hardDiscMenu.section("Drive :\(drive + 4)" + (name.map { " — \($0)" } ?? "")) { section in
                section.item("New Hard Disc…", "win.new-hard-disc", string: String(drive))
                section.item("New Hard Disc from Files…", "win.new-hard-disc-from-files", string: String(drive))
                section.item("Open Hard Disc…", "win.open-hard-disc", string: String(drive))
                if name != nil {
                    section.item("Show Hard Disc Contents", "win.disc-contents", string: String(drive))
                    section.item("Add Files to Hard Disc…", "win.add-files-to-hard-disc", string: String(drive))
                    section.item("Resize Hard Disc…", "win.resize-hard-disc", string: String(drive))
                    section.item("Remove Hard Disc", "win.eject-hard-disc", string: String(drive))
                }
            }
        }
    }

    // MARK: Actions

    private func addActions() {
        let machine = machine
        let actions = actions!
        actions.add("open-disc") { machine.openDisc() }
        actions.add("arclibre-extras") {
            guard let disc = AppSettings.shared.arcLibreExtrasDisc else { return }
            Task { @MainActor in await machine.insertDisc(disc) }
        }
        actions.add("open-recent", string: { path in
            Task { @MainActor in await machine.insertDisc(URL(fileURLWithPath: path)) }
        })
        actions.add("clear-recent") { AppSettings.shared.clearRecents() }
        actions.add("new-disc", string: { format in
            guard let format = ADFSFloppyFormatter.Format(rawValue: format) else { return }
            Task { @MainActor in await machine.insertBlankDisc(format) }
        })
        actions.add("save-disc") { Task { @MainActor in await machine.saveDisc() } }
        actions.add("save-disc-as") { Task { @MainActor in await machine.saveDiscAs() } }
        actions.add("eject-disc") { Task { @MainActor in await machine.ejectDisc() } }
        actions.add("disc-contents", string: { drive in machine.showDiscContents(Int(drive).map { .hard($0) } ?? .floppy) })

        actions.add("new-hard-disc", string: { drive in Task { @MainActor in await machine.newHardDisc(drive: Int(drive) ?? 0) } })
        actions.add("new-hard-disc-from-files", string: { drive in
            Task { @MainActor in await machine.newHardDiscFromFiles(drive: Int(drive) ?? 0) }
        })
        actions.add("open-hard-disc", string: { drive in machine.openHardDisc(drive: Int(drive) ?? 0) })
        actions.add("add-files-to-hard-disc", string: { drive in
            Task { @MainActor in await machine.addFilesToHardDisc(drive: Int(drive) ?? 0) }
        })
        actions.add("resize-hard-disc", string: { drive in Task { @MainActor in await machine.resizeHardDisc(drive: Int(drive) ?? 0) } })
        actions.add("eject-hard-disc", string: { drive in machine.ejectHardDisc(drive: Int(drive) ?? 0) })

        actions.add("screenshot") { machine.saveScreenshot() }
        actions.add("copy-screenshot") { machine.copyScreenshot() }
        actions.add("paste-text") { machine.pasteText() }
        actions.addToggle("record", state: false) { _ in machine.toggleRecording() }
        actions.add("save-state") { machine.saveState() }
        actions.add("load-state") { machine.loadState() }
        actions.add("quick-save") { machine.quickSave() }
        actions.add("quick-load") { machine.quickLoad() }

        actions.addToggle("pause", state: false) { _ in machine.togglePause() }
        actions.addToggle("full-speed", state: false) { _ in machine.toggleSpeedLimit() }
        actions.addToggle("mute", state: false) { on in machine.muted = on }
        actions.addToggle("disc-drive-sounds", state: AppSettings.shared.discDriveSounds) { on in MachineController.setDiscDriveSounds(on) }
        actions.add("reset") { machine.reset() }
        actions.add("power-cycle") { machine.powerCycle() }
        actions.addRadio("mouse-mode", state: AppSettings.shared.mouseMode.rawValue) { value in
            if let mode = AppSettings.MouseMode(rawValue: value) { AppSettings.shared.mouseMode = mode }
        }
        actions.add("capture-mouse") { machine.toggleMouseCapture() }
        actions.add("rewind", string: { seconds in machine.rewind(seconds: Double(seconds) ?? 5) })
        actions.add("timeline") { machine.showingTimeline = true }
        actions.add("configure") { [weak self] in self?.showConfigure() }
        actions.addRadio("model", state: machine.model.rawValue) { value in
            if let model = MachineModel(rawValue: value) { machine.setHardware(model: model) }
        }
        actions.addRadio("cpu", state: machine.cpu.rawValue) { value in
            if let cpu = CPUType(rawValue: value) { machine.setHardware(cpu: cpu) }
        }
        actions.addRadio("memory", state: String(machine.ramKB)) { value in
            if let kb = Int(value) { machine.setHardware(ramKB: kb) }
        }
        actions.addRadio("monitor", state: machine.monitor.rawValue) { value in
            if let monitor = MonitorType(rawValue: value) { machine.setHardware(monitor: monitor) }
        }
        actions.addRadio("rom", state: machine.romPath ?? "") { path in machine.setHardware(romPath: path) }
        actions.add("add-roms") { [weak self] in ROMLibrary.shared.chooseAndAdd(parent: self?.window) }
        actions.add("import-configuration") { machine.chooseImportConfiguration() }
        actions.add("export-configuration") { machine.chooseExportConfiguration() }

        actions.addRadio("display-style", state: machine.displayStyle.rawValue) { value in
            guard let style = DisplayStyle(rawValue: value) else { return }
            // All windows show the same style.
            for window in Self.all { window.machine.displayStyle = style }
        }
        actions.addRadio("display-border", state: machine.displayBorder.rawValue) { value in
            guard let border = DisplayBorder(rawValue: value) else { return }
            for window in Self.all { window.machine.displayBorder = border }
        }
        actions.addRadio("zoom", state: "100") { value in
            if let percent = Double(value) { machine.setZoom(percent / 100) }
        }
        actions.add("actual-size") { machine.setZoom(1) }
        actions.add("zoom-in") { machine.zoom(in: true) }
        actions.add("zoom-out") { machine.zoom(in: false) }
        actions.add("widescreen") { machine.makeWidescreen() }
        actions.addToggle("fullscreen", state: false) { [weak self] on in
            guard let self else { return }
            if on { gtk_window_fullscreen(self.window.cast()) } else { gtk_window_unfullscreen(self.window.cast()) }
        }
        onNotify(window, "fullscreened") { [weak self] in
            guard let self else { return }
            let fullscreen = gtk_window_is_fullscreen(self.window.cast()) != 0
            self.actions["fullscreen"]?.setState(fullscreen)
            // The picture alone, edge to edge.
            adw_toolbar_view_set_reveal_top_bars(self.toolbarView.cast(), fullscreen ? 0 : 1)
            if fullscreen { self.machine.show("Press F11 to leave fullscreen") }
        }
        actions.addRadio("keyboard-mode", state: KeyboardSettings.shared.mode.rawValue) { value in
            if let mode = KeyboardSettings.Mode(rawValue: value) { KeyboardSettings.shared.mode = mode }
        }

        actions.add("next-disc") { machine.insertNextSessionDisc() }
        actions.add("debugger") { machine.debuggerRequested = true }
        actions.add("debug-break") {
            machine.debugger.pauseOrContinue()
            // Breaking in opens the debugger.
            machine.debuggerRequested = machine.debugStop == nil
        }
    }

    /// The actions that need a running machine.
    private static let machineActions = [
        "open-disc", "arclibre-extras", "open-recent", "new-disc", "save-disc", "save-disc-as", "eject-disc", "screenshot", "copy-screenshot",
        "paste-text", "save-state", "load-state", "quick-save", "quick-load", "pause", "full-speed", "reset", "power-cycle",
        "capture-mouse", "rewind", "timeline", "zoom", "actual-size", "zoom-in", "zoom-out", "widescreen", "export-configuration",
        "record", "debugger", "debug-break", "disc-contents",
    ]

    /// Keeps the actions, menus, title and pages in step with the machine.
    private func observeMachine() {
        let machine = machine
        observe(self) { [weak self] in
            guard let self else { return }
            let actions = self.actions!
            let running = machine.host != nil
            for name in Self.machineActions {
                actions[name]?.isEnabled = running
            }
            actions["save-disc"]?.isEnabled = running && machine.disc.modified && machine.disc.savable
            actions["save-disc-as"]?.isEnabled = running && machine.discName != nil && (machine.disc.savable || machine.discIsUntitled)
            actions["eject-disc"]?.isEnabled = running && machine.discName != nil
            actions["capture-mouse"]?.isEnabled = running && AppSettings.shared.mouseMode == .capture
            actions["pause"]?.setState(machine.isStill)
            actions["record"]?.setState(machine.recordingURL != nil)
            // A network's station has its setup kept by its network.
            actions["import-configuration"]?.isEnabled = !machine.isStation
            actions["export-configuration"]?.isEnabled = running && !machine.isStation
            actions["next-disc"]?.isEnabled = running && machine.sessionDiscsActive
            actions["full-speed"]?.setState(!machine.speedLimited)
            actions["mute"]?.setState(machine.muted)
            actions["disc-drive-sounds"]?.setState(AppSettings.shared.discDriveSounds)
            actions["model"]?.setState(machine.model.rawValue)
            actions["cpu"]?.setState(machine.cpu.rawValue)
            actions["memory"]?.setState(String(machine.ramKB))
            actions["monitor"]?.setState(machine.monitor.rawValue)
            actions["rom"]?.setState(machine.romPath ?? "")
            actions["display-style"]?.setState(machine.displayStyle.rawValue)
            actions["display-border"]?.setState(machine.displayBorder.rawValue)
            actions["zoom"]?.setState(machine.zoom.map(Self.zoomName) ?? "")
            actions["mouse-mode"]?.setState(AppSettings.shared.mouseMode.rawValue)
            self.emulator.style = machine.displayStyle
            self.emulator.border = machine.displayBorder
            for button in self.machineButtons { button.setSensitive(running) }
            self.hardDiscButton?.setVisible(machine.model.hardDiscSlots > 0)
            gtk_stack_set_visible_child_name(self.stack.cast(), running ? "machine" : "setup")
            self.updateTitle()
            self.updatePauseItem()
        }
        observe(self) { [weak self] in
            guard let self else { return }
            _ = (machine.model, machine.hardDiscs)
            self.updateHardwareMenus()
        }
        observe(self) { [weak self] in
            self?.actions["keyboard-mode"]?.setState(KeyboardSettings.shared.mode.rawValue)
        }
        observe(self) { [weak self] in
            _ = AppSettings.shared.recentDiscs
            self?.updateRecentMenu()
        }
        observe(self) { [weak self] in
            _ = AppSettings.shared.romLibrary
            self?.updateROMMenu()
        }
        observe(self) { [weak self] in
            guard let self else { return }
            self.recentNetworksMenu.removeAll()
            for url in RecentNetworks.shared.existing {
                self.recentNetworksMenu.item(url.deletingPathExtension().lastPathComponent, "app.network-recent", string: url.path)
            }
        }
        observe(self) { [weak self] in
            // Leaving capture mode lets the mouse go.
            if AppSettings.shared.mouseMode == .follow { self?.emulator.setMouseCaptured(false) }
        }
        observe(self) { [weak self] in
            guard let self, let toast = machine.toast else { return }
            let shown = adw_toast_new(toast)!
            adw_toast_set_timeout(shown, 2)
            adw_toast_overlay_add_toast(self.toastOverlay.cast(), shown)
        }
        observe(self) { [weak self] in
            guard let self else { return }
            let inspection = machine.inspection
            UI.setText(self.inspectionLabel, inspection ?? "")
            self.inspectionLabel.setVisible(inspection?.isEmpty == false)
        }
        observe(self) { [weak self] in
            guard let self, machine.discContentsRequested else { return }
            after(0) { [weak self] in
                machine.discContentsRequested = false
                self?.showDiscContents(machine.discContentsDrive)
            }
        }
        observe(self) { [weak self] in
            guard let self, machine.debuggerRequested else { return }
            after(0) { [weak self] in
                guard let self else { return }
                machine.debuggerRequested = false
                self.showDebugger()
            }
        }
        observe(self) { [weak self] in
            guard let self, machine.showingTimeline else { return }
            after(0) { [weak self] in
                guard let self, self.rewindDialog == nil else { return }
                self.rewindDialog = RewindDialog(machine: machine, parent: self.window) { [weak self] in
                    machine.showingTimeline = false
                    self?.rewindDialog = nil
                }
            }
        }
    }

    /// Menu items whose words follow the machine.
    private var shownItems: (still: Bool, recording: Bool, stopped: Bool, nextDisc: String)?

    private func updatePauseItem() {
        let items = (machine.isStill, machine.recordingURL != nil, machine.debugStop != nil, machine.nextSessionDiscTitle)
        guard shownItems.map({ $0 != items }) ?? true else { return }
        shownItems = items
        pauseSection.removeAll()
        pauseSection.item(items.0 ? "Resume" : "Pause", "win.pause")
        recordSection.removeAll()
        recordSection.item(items.1 ? "Stop Recording" : "Start Recording…", "win.record")
        debugSection.removeAll()
        debugSection.item(items.2 ? "Continue" : "Break into Debugger", "win.debug-break")
        nextDiscSection.removeAll()
        nextDiscSection.item(items.3, "win.next-disc")
    }

    private func updateTitle() {
        var (title, notes) = machine.title
        if mouseCaptured {
            notes.append(EmulatorView.captureHint)
        }
        adw_window_title_set_title(windowTitle, title)
        adw_window_title_set_subtitle(windowTitle, notes.joined(separator: " · "))
        gtk_window_set_title(window.cast(), notes.isEmpty ? title : "\(title) (\(notes.joined(separator: ", ")))")
    }

    // MARK: Zoom

    /// Resizes the window so the picture is `zoom` times the frame's actual
    /// size (as big as fits, if that's less).
    func applyZoom(_ zoom: Double) {
        if gtk_window_is_maximized(window.cast()) != 0 {
            gtk_window_unmaximize(window.cast())
        }
        let aspect = emulator.aspect
        let actual = emulator.renderer?.actualSize.height ?? 576
        // The screen fills the window below the header bar.
        let chrome = Double(gtk_widget_get_height(window)) - Double(gtk_widget_get_height(emulator.area))
        var height = actual * zoom
        if let monitor = currentMonitor() {
            var geometry = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &geometry)
            height = min(height, Double(geometry.height) - chrome - 48, Double(geometry.width) / aspect)
        }
        let width = (height * aspect).rounded()
        gtk_window_set_default_size(window.cast(), Int32(width), Int32((height + chrome).rounded()))
    }

    /// Makes the window 16:9 at its height (less, if that's wider than the
    /// screen).
    func makeWidescreen() {
        if gtk_window_is_maximized(window.cast()) != 0 {
            gtk_window_unmaximize(window.cast())
        }
        var height = Double(gtk_widget_get_height(window))
        if let monitor = currentMonitor() {
            var geometry = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &geometry)
            height = min(height, Double(geometry.width) * 9 / 16)
        }
        gtk_window_set_default_size(window.cast(), Int32((height * 16 / 9).rounded()), Int32(height.rounded()))
    }

    private func currentMonitor() -> OpaquePointer? {
        guard let surface = gtk_native_get_surface(window.opaque) else { return nil }
        return gdk_display_get_monitor_at_surface(gdk_display_get_default(), surface)
    }

    // MARK: Other windows

    func showDiscContents(_ drive: DiscDrive? = nil) {
        if let discContentsWindow {
            discContentsWindow.present(drive: drive)
            return
        }
        let window = DiscContentsWindow(machine: machine)
        window.onClose = { [weak self] in self?.discContentsWindow = nil }
        discContentsWindow = window
        window.present(drive: drive)
    }

    func showDebugger() {
        if let debuggerWindow {
            debuggerWindow.present()
            return
        }
        let debugger = DebuggerWindow(model: machine.debugger, machineName: machine.machineName)
        debugger.onClose = { [weak self] in self?.debuggerWindow = nil }
        debuggerWindow = debugger
        debugger.present()
    }

    func showConfigure() {
        if let configureDialog {
            configureDialog.present()
            return
        }
        let dialog = ConfigureMachineDialog(machine: machine, parent: window) { [weak self] in self?.configureDialog = nil }
        configureDialog = dialog
        dialog.present()
    }
}

/// Network stations' own windows: the same window a standalone machine has,
/// menus and all. Closing one leaves its station running.
@MainActor
enum StationWindows {
    /// Opens (or brings forward) the station's window.
    static func open(_ controller: MachineController) {
        if let window = MachineWindow.all.first(where: { $0.machine === controller }) {
            window.present()
            return
        }
        let window = MachineWindow(app: LinuxArchApp.shared.app, machine: controller)
        window.present()
    }

    /// The station's been switched off: its window goes.
    static func close(_ controller: MachineController) {
        for window in MachineWindow.all where window.machine === controller {
            window.forceClose()
        }
    }
}
