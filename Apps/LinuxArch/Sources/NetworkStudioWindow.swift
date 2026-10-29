import ArchimedesCore
import CGtk
import Foundation

/// A network's window: its machines on the canvas, side by side in tiles,
/// one large with the rest in a strip, its traffic, or the Distributed
/// Mandelbrot demo's picture; and the inspector for what's selected. (The
/// Mac app's Network Studio.)
@MainActor
final class NetworkStudioWindow {
    /// Open studios, by network.
    private static var open: [URL: NetworkStudioWindow] = [:]

    /// Opens a network's window (opening the network), or brings it forward.
    @discardableResult
    static func show(_ url: URL) -> NetworkStudioWindow? {
        let key = NetworkSession.key(url)
        if let studio = open[key] {
            studio.present()
            return studio
        }
        do {
            let session = try NetworkSession.session(for: key)
            let studio = NetworkStudioWindow(session: session)
            open[key] = studio
            studio.present()
            return studio
        } catch {
            RecentNetworks.shared.remove(url)
            Alerts.show("Can’t open the network", "\(error)", parent: frontWindow)
            return nil
        }
    }

    /// Quitting: every network is saved and stops.
    static func closeAll() {
        for studio in open.values { gtk_window_close(studio.window.cast()) }
        for session in NetworkSession.open.values { session.close() }
    }

    /// Shows a view in every studio (for self-tests).
    static func showMode(_ name: String) {
        guard let mode = Mode(rawValue: name) else { return }
        for studio in open.values {
            adw_toggle_group_set_active_name(studio.modes.cast(), mode.rawValue)
            studio.present()
        }
    }

    /// The network that's open, else the last one, else a new one.
    static func showStudio() {
        if let url = NetworkSession.open.keys.first ?? RecentNetworks.shared.existing.first {
            show(url)
        } else {
            NetworkStartWindow.show()
        }
    }

    /// A network's package, chosen.
    static func chooseAndOpen(parent: Widget?) {
        try? FileManager.default.createDirectory(at: RecentNetworks.folder, withIntermediateDirectories: true)
        FileDialogs.chooseFolder(parent: parent, title: "Open Network (a .\(NetworkPackage.fileExtension) folder)", initial: RecentNetworks.folder) { url in
            show(url)
        }
    }

    enum Mode: String, CaseIterable {
        case canvas, tiles, focus, traffic, mandelbrot

        var title: String {
            switch self {
            case .canvas: "Canvas"
            case .tiles: "Tiles"
            case .focus: "Focus"
            case .traffic: "Traffic"
            case .mandelbrot: "Mandelbrot"
            }
        }
    }

    let session: NetworkSession
    let window: Widget
    private let windowTitle: OpaquePointer
    private let split: Widget
    private let content: Widget
    private let modes: Widget
    private var mode: Mode
    private var view: AnyObject?
    private var closeView: Handler?
    private let inspector: NetworkInspectorView
    /// Follows the Distributed Mandelbrot demo once its view's been shown.
    let mandelbrot = MandelbrotFeed()
    private var debuggers: [UUID: DebuggerWindow] = [:]
    private var internetDialog: InternetShareDialog?

    private init(session: NetworkSession) {
        self.session = session
        mode = ProcessInfo.processInfo.environment["LINUXARCH_SELFTEST_NETWORK_MODE"].flatMap(Mode.init(rawValue:)) ?? .canvas
        window = adw_application_window_new(LinuxArchApp.shared.app.cast())!
        gtk_window_set_default_size(window.cast(), 1180, 780)
        windowTitle = OpaquePointer(adw_window_title_new(session.project.name, "")!)
        split = adw_overlay_split_view_new()!
        content = UI.vbox()
        modes = adw_toggle_group_new()!
        inspector = NetworkInspectorView(session: session)
        inspector.studio = self
        build()
        show(mode)
        observeSession()
        onSignalReturning(window, "close-request") { [weak self] in
            guard let self else { return false }
            self.closed()
            return false
        }
    }

    func present() {
        gtk_window_present(window.cast())
    }

    private func closed() {
        closeView?()
        mandelbrot.hidden()
        for debugger in debuggers.values { debugger.close() }
        internetDialog?.close()
        for controller in session.controllers.values { StationWindows.close(controller) }
        Self.open[session.url] = nil
        session.close()
    }

    // MARK: Building

    private func build() {
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(header.cast(), windowTitle.widget)
        for mode in Mode.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, mode.rawValue)
            adw_toggle_set_label(toggle, mode.title)
            adw_toggle_group_add(modes.cast(), toggle)
        }
        adw_toggle_group_set_active_name(modes.cast(), mode.rawValue)
        modes.setTooltip("Arrange the network, or use its machines side by side")
        onNotify(modes, "active-name") { [weak self] in
            guard let self, let name = String(gBorrowed: adw_toggle_group_get_active_name(self.modes.cast())),
                  let mode = Mode(rawValue: name), mode != self.mode else { return }
            self.show(mode)
        }
        adw_header_bar_pack_start(header.cast(), modes)

        let session = session
        let inspectorButton = gtk_toggle_button_new()!
        gtk_button_set_icon_name(inspectorButton.cast(), "sidebar-show-right-symbolic")
        inspectorButton.setTooltip("Show or hide the inspector")
        la_set_int(inspectorButton.raw, "active", 1)
        let pause = UI.iconButton("media-playback-pause-symbolic", tooltip: "") { session.setPaused(!session.paused) }
        let reset = UI.iconButton("view-refresh-symbolic", tooltip: "Press every machine’s reset button") { [weak self] in
            Task {
                guard await Alerts.confirm("Reset every machine?", "Each machine restarts, as if its reset button were pressed. Programs that are running stop.",
                                           button: "Reset All", parent: self?.window) else { return }
                session.resetAll()
            }
        }
        let powerOff = UI.iconButton("system-shutdown-symbolic", tooltip: "Switch off every machine") { [weak self] in
            Task {
                guard await Alerts.confirm("Switch every machine off?", "What’s in their memory is lost. Their discs are kept.",
                                           button: "Power Off All", destructive: true, parent: self?.window) else { return }
                session.powerOffAll()
            }
        }
        let powerOn = UI.button("Power On All", classes: ["flat"]) { session.powerOnAll() }
        powerOn.setTooltip("Switch on every machine")
        let internet = UI.iconButton("network-workgroup-symbolic", tooltip: "") { [weak self] in self?.showInternet() }
        let group = g_simple_action_group_new()!
        let actions = Actions(OpaquePointer(group))
        gtk_widget_insert_action_group(window, "studio", OpaquePointer(group))
        g_object_unref(group.raw)
        actions.add("save-as") { [weak self] in self?.saveAs() }
        actions.add("internet") { [weak self] in self?.showInternet() }
        let menu = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(menu.cast(), "open-menu-symbolic")
        menu.setTooltip("Main Menu")
        gtk_menu_button_set_menu_model(menu.cast(), Menu()
            .section { section in
                section.item("New Network…", "app.network-new")
                section.item("Open Network…", "app.network-open")
                section.item("Save Network As…", "studio.save-as")
            }
            .section { section in
                section.item("Share Over Internet…", "studio.internet")
                section.item("Join Econet Network…", "app.network-join")
            }
            .section { section in
                section.item("New Archimedes Window", "app.new-window")
                section.item("Game Library", "app.game-library")
                section.item("Preferences", "app.preferences")
            }.model)
        for button in [menu, inspectorButton, pause, reset, powerOff, powerOn, internet] {
            adw_header_bar_pack_end(header.cast(), button)
        }
        observe(self) {
            gtk_button_set_icon_name(pause.cast(), session.paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic")
            pause.setTooltip(session.paused ? "Carry on: every machine starts again together" : "Stop time on the whole network: nothing times out")
            reset.setSensitive(!session.controllers.isEmpty)
            powerOff.setSensitive(!session.controllers.isEmpty)
            internet.setTooltip(session.isInRoom ? "This network’s Internet room: invitations, who’s in it, and leaving"
                                : "Share this network over the Internet, with a link or a code: MacArch, LinuxArch and MacBeeb users can join")
            gtk_button_set_icon_name(internet.cast(), session.isInRoom ? "network-wireless-symbolic" : "network-workgroup-symbolic")
        }

        content.expand(horizontally: true, vertically: true)
        let inspectorScroll = UI.scrolled(inspector.widget)
        gtk_widget_set_size_request(inspectorScroll, 290, -1)
        adw_overlay_split_view_set_content(split.cast(), content)
        adw_overlay_split_view_set_sidebar(split.cast(), inspectorScroll)
        adw_overlay_split_view_set_sidebar_position(split.cast(), GTK_PACK_END)
        adw_overlay_split_view_set_min_sidebar_width(split.cast(), 290)
        adw_overlay_split_view_set_max_sidebar_width(split.cast(), 320)
        _ = g_object_bind_property(inspectorButton.raw, "active", split.raw, "show-sidebar",
                                   GBindingFlags(rawValue: 1 | 2) /* bidirectional, sync-create */)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), split)
        adw_application_window_set_content(window.cast(), toolbar)
        let narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 900sp"))!
        la_breakpoint_set_bool(narrow, split.raw, "collapsed", 1)
        adw_application_window_add_breakpoint(window.cast(), narrow)

        // Disc images dropped on the studio go in the selected machine.
        acceptFileDrops(on: window) { urls in
            guard session.selection.count == 1, let id = session.selection.first, let url = urls.first,
                  let controller = session.controllers[id] else { return false }
            Task { await controller.insertDisc(url) }
            return true
        }
    }

    /// Shows a mode's view (making it afresh: the one before stops).
    private func show(_ mode: Mode) {
        self.mode = mode
        closeView?()
        UI.removeAll(content)
        let shown: Widget
        switch mode {
        case .canvas:
            let canvas = NetworkCanvasView(session: session, studio: self)
            view = canvas
            closeView = { canvas.close() }
            shown = canvas.widget
        case .tiles:
            let tiles = NetworkTilesView(session: session, studio: self)
            view = tiles
            closeView = { tiles.close() }
            shown = tiles.widget
        case .focus:
            let focus = NetworkFocusView(session: session, studio: self)
            view = focus
            closeView = { focus.close() }
            shown = focus.widget
        case .traffic:
            let traffic = NetworkTrafficView(session: session, parent: window)
            view = traffic
            closeView = { traffic.close() }
            shown = traffic.widget
        case .mandelbrot:
            let picture = NetworkMandelbrotView(session: session, feed: mandelbrot)
            view = picture
            closeView = { picture.close() }
            shown = picture.widget
        }
        shown.expand(horizontally: true, vertically: true)
        UI.append(content, shown)
    }

    private func observeSession() {
        let session = session
        observe(self) { [weak self] in
            guard let self else { return }
            adw_window_title_set_title(self.windowTitle, session.project.name)
            adw_window_title_set_subtitle(self.windowTitle, self.subtitle)
            gtk_window_set_title(self.window.cast(), session.project.name + " — Network Studio")
        }
        observe(self) { [weak self] in
            guard let self, let problem = session.saveError else { return }
            after(0) { [weak self] in Alerts.show("Can’t save the network", problem, parent: self?.window) }
        }
        observe(self) { [weak self] in
            guard let self, session.showingInternet else { return }
            after(0) { [weak self] in
                session.showingInternet = false
                self?.showInternet()
            }
        }
    }

    /// The station holding the mouse, whose release the subtitle explains.
    var capturing: MachineController? {
        didSet { adw_window_title_set_subtitle(windowTitle, subtitle) }
    }

    private var subtitle: String {
        if capturing != nil { return EmulatorView.captureHint }
        let on = session.controllers.count
        let machines = session.project.nodes.filter(\.isMachine).count
        var text = "\(on) of \(machines) on"
        if session.paused {
            text += " · Paused"
        } else if !session.status.stoppedStations.isEmpty && session.network.pausesOnBreakpoint {
            text += " · Paused for the debugger"
        } else if on > 0 && session.status.speed > 0 {
            text += String(format: " · %.0f%% speed", min(session.status.speed, 9.99) * 100)
        }
        return text
    }

    /// Saves a copy elsewhere and carries on with the copy.
    private func saveAs() {
        let session = session
        FileDialogs.save(parent: window, title: "Save Network As", name: session.url.lastPathComponent,
                         folder: session.url.deletingLastPathComponent()) { [weak self] url in
            guard let self else { return }
            var target = url
            if target.pathExtension.lowercased() != NetworkPackage.fileExtension {
                target = target.appendingPathExtension(NetworkPackage.fileExtension)
            }
            let old = session.url
            do {
                try session.saveAs(target)
                Self.open[old] = nil
                Self.open[session.url] = self
            } catch {
                Alerts.show(error, parent: self.window)
            }
        }
    }

    // MARK: Other windows

    func openStation(_ id: UUID) {
        guard let controller = session.controllers[id] else { return }
        StationWindows.open(controller)
    }

    func openDebugger(_ id: UUID) {
        guard let controller = session.controllers[id] else { return }
        // In its own window, if it has one.
        if let station = MachineWindow.all.first(where: { $0.machine === controller }) {
            station.showDebugger()
            return
        }
        if let debugger = debuggers[id] {
            debugger.present()
            return
        }
        let name = session.node(id)?.name ?? controller.machineName
        let debugger = DebuggerWindow(model: controller.debugger, machineName: name)
        debugger.onClose = { [weak self] in self?.debuggers[id] = nil }
        debuggers[id] = debugger
        debugger.present()
    }

    func openConfigure(_ id: UUID) {
        if !session.isOn(id) { session.powerOn(id) }
        guard let controller = session.controllers[id] else { return }
        ConfigureMachineDialog(machine: controller, parent: window) {}.present()
    }

    func showInternet() {
        if let internetDialog {
            internetDialog.present()
            return
        }
        let dialog = InternetShareDialog(session: session, parent: window) { [weak self] in self?.internetDialog = nil }
        internetDialog = dialog
        dialog.present()
    }
}

// MARK: Tiles

/// One machine, live and full size enough to use, with its name over it.
/// The one with the keyboard has a ring round it, and it's the one heard.
@MainActor
final class StationTile {
    let widget: Widget
    let controller: MachineController
    let emulator: EmulatorView
    private let name: Widget
    private let summary: Widget
    private let heard: Widget

    init(session: NetworkSession, node: NetworkNode, controller: MachineController, studio: NetworkStudioWindow?) {
        self.controller = controller
        emulator = EmulatorView()
        emulator.machine = controller
        emulator.style = controller.displayStyle
        emulator.border = controller.displayBorder
        emulator.setMinimumSize(width: 200, height: 150)
        let id = node.id
        emulator.onFocus = { session.focus(id) }
        emulator.onMouseCapture = { [weak studio] captured in
            studio?.capturing = captured ? controller : (studio?.capturing === controller ? nil : studio?.capturing)
        }
        let badge = UI.label(node.stationNumber.map(String.init) ?? "–", classes: ["station-badge"], xalign: 0.5)
        name = UI.label(node.name, classes: ["heading"])
        summary = UI.label(node.setup?.summary ?? "", classes: ["caption", "dim-label"])
        gtk_label_set_ellipsize(summary.cast(), PANGO_ELLIPSIZE_END)
        summary.expand(horizontally: true)
        heard = UI.image(icon: "audio-volume-high-symbolic")
        heard.addClass("dim-label")
        heard.setTooltip("Heard")
        let open = UI.iconButton("window-new-symbolic", tooltip: "Open in its own window", classes: ["flat"]) { [weak studio] in
            studio?.openStation(id)
        }
        let bar = UI.hbox(spacing: 6, [badge, name, summary, heard, open])
        bar.setMargins(top: 4, bottom: 4, start: 8, end: 4)
        let screen = UI.vbox(spacing: 0, [emulator.area], classes: ["emulator-background"])
        screen.expand(horizontally: true, vertically: true)
        widget = UI.vbox(spacing: 0, [bar, screen], classes: ["station-tile"])
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        widget.expand(horizontally: true, vertically: true)
        // In the tiles, a 4:3 screen under its bar, as big as fits.
        frame = gtk_aspect_frame_new(0.5, 0, Float(NetworkCanvasView.screenAspect * 0.92), 0)!
        gtk_aspect_frame_set_child(frame.cast(), widget)
        frame.expand(horizontally: true, vertically: true)
    }

    /// The tile at its proportions, for the tiles' grid.
    let frame: Widget

    func update(_ node: NetworkNode, focused: Bool) {
        UI.setText(name, node.name)
        UI.setText(summary, node.setup?.summary ?? "")
        heard.setVisible(focused)
        widget.setClass("focused", focused)
    }

    func close() {
        emulator.setMouseCaptured(false)
    }
}

/// The machines side by side, each live and full size enough to use.
@MainActor
final class NetworkTilesView {
    let widget: Widget
    private let session: NetworkSession
    private weak var studio: NetworkStudioWindow?
    private let grid: Widget
    private let empty: Widget
    private let scroll: Widget
    private let keyboardLabel: Widget
    private var tiles: [UUID: StationTile] = [:]
    private var shownLayout: ([UUID], Int)?

    init(session: NetworkSession, studio: NetworkStudioWindow) {
        self.session = session
        self.studio = studio
        grid = gtk_grid_new()!
        gtk_grid_set_row_spacing(grid.cast(), 10)
        gtk_grid_set_column_spacing(grid.cast(), 10)
        gtk_grid_set_row_homogeneous(grid.cast(), 1)
        gtk_grid_set_column_homogeneous(grid.cast(), 1)
        grid.setMargins(10)
        grid.expand(horizontally: true, vertically: true)
        empty = NetworkTilesView.noneOn(session)
        scroll = UI.scrolled(grid)
        scroll.expand(horizontally: true, vertically: true)
        keyboardLabel = UI.label("", classes: ["dim-label"])
        widget = UI.vbox(spacing: 0, classes: ["network-background"])
        UI.append(widget, tileBar())
        UI.append(widget, UI.separator())
        UI.append(widget, empty)
        UI.append(widget, scroll)
        observe(self) { [weak self] in self?.update() }
    }

    func close() {
        for tile in tiles.values { tile.close() }
    }

    /// "No machines on", with Power On All.
    static func noneOn(_ session: NetworkSession) -> Widget {
        let page = adw_status_page_new()!
        adw_status_page_set_title(page.cast(), "No Machines On")
        adw_status_page_set_description(page.cast(), "Switch machines on in the canvas, or with Power On All.")
        adw_status_page_set_icon_name(page.cast(), "system-shutdown-symbolic")
        let button = UI.button("Power On All", classes: ["pill", "suggested-action"]) { session.powerOnAll() }
        button.align(horizontal: GTK_ALIGN_CENTER)
        adw_status_page_set_child(page.cast(), button)
        page.expand(horizontally: true, vertically: true)
        return page
    }

    private func tileBar() -> Widget {
        let session = session
        // Which machines: all that are on, or those chosen.
        let show = gtk_menu_button_new()!
        gtk_menu_button_set_label(show.cast(), "Show")
        gtk_menu_button_set_icon_name(show.cast(), "view-grid-symbolic")
        let chooser = UI.vbox(spacing: 4)
        chooser.setMargins(8)
        let popover = gtk_popover_new()!
        gtk_popover_set_child(popover.cast(), chooser)
        gtk_menu_button_set_popover(show.cast(), popover)
        onSignal(popover, "show") {
            UI.removeAll(chooser)
            UI.append(chooser, UI.button("Every Machine That’s On", classes: ["flat"]) { session.update { $0.workspace.tiles = [] } })
            for node in session.project.stations {
                let tiles = session.project.workspace.tiles
                UI.append(chooser, UI.check(node.name, active: tiles.isEmpty || tiles.contains(node.id)) { on in
                    session.update { project in
                        var chosen = project.workspace.tiles.isEmpty ? project.stations.map(\.id) : project.workspace.tiles
                        if on { if !chosen.contains(node.id) { chosen.append(node.id) } } else { chosen.removeAll { $0 == node.id } }
                        project.workspace.tiles = chosen
                    }
                })
            }
        }
        let columns = adw_toggle_group_new()!
        for (name, label) in [("0", "Fit"), ("2", "2"), ("3", "3"), ("4", "4")] {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, name)
            adw_toggle_set_label(toggle, label)
            adw_toggle_group_add(columns.cast(), toggle)
        }
        adw_toggle_group_set_active_name(columns.cast(), "\(session.project.workspace.columns)")
        columns.setTooltip("Columns")
        onNotify(columns, "active-name") {
            guard let name = String(gBorrowed: adw_toggle_group_get_active_name(columns.cast())), let value = Int(name),
                  value != session.project.workspace.columns else { return }
            session.update { $0.workspace.columns = value }
        }
        let previous = UI.iconButton("go-previous-symbolic", tooltip: "The previous machine gets the keyboard", classes: ["flat"]) { [weak self] in
            self?.step(false)
        }
        let next = UI.iconButton("go-next-symbolic", tooltip: "The next machine gets the keyboard", classes: ["flat"]) { [weak self] in
            self?.step(true)
        }
        let bar = UI.hbox(spacing: 12, [show, columns, UI.spacer(), previous, next, keyboardLabel])
        bar.setMargins(top: 6, bottom: 6, start: 12, end: 12)
        return bar
    }

    private func step(_ forward: Bool) {
        session.focusNext(forward)
        if let id = session.focused { tiles[id]?.emulator.grabFocus() }
    }

    private func columnCount(_ count: Int) -> Int {
        let chosen = session.project.workspace.columns
        if chosen > 0 { return min(chosen, max(count, 1)) }
        // As square as fits.
        let width = Double(gtk_widget_get_width(widget))
        let fit = max(1, Int((width > 0 ? width : 1000) / 300))
        return min(fit, max(1, Int(Double(count).squareRoot().rounded(.up))))
    }

    private func update() {
        let chosen = session.project.workspace.tiles
        let shown = session.project.stations.filter { session.isOn($0.id) && (chosen.isEmpty || chosen.contains($0.id)) }
        empty.setVisible(shown.isEmpty)
        scroll.setVisible(!shown.isEmpty)
        // Tiles for the machines on (a machine switched off and on gets a
        // new one: its view takes its machine when it's made).
        for (id, tile) in tiles where !shown.contains(where: { $0.id == id }) || session.controllers[id] !== tile.controller {
            tile.close()
            if gtk_widget_get_parent(tile.frame) != nil { gtk_grid_remove(grid.cast(), tile.frame) }
            tiles[id] = nil
        }
        for node in shown where tiles[node.id] == nil {
            guard let controller = session.controllers[node.id] else { continue }
            tiles[node.id] = StationTile(session: session, node: node, controller: controller, studio: studio)
        }
        let columns = columnCount(shown.count)
        let layout = (shown.map(\.id), columns)
        if shownLayout.map({ $0.0 != layout.0 || $0.1 != layout.1 }) ?? true {
            shownLayout = layout
            for tile in tiles.values where gtk_widget_get_parent(tile.frame) != nil { gtk_grid_remove(grid.cast(), tile.frame) }
            for (index, node) in shown.enumerated() {
                guard let tile = tiles[node.id] else { continue }
                gtk_grid_attach(grid.cast(), tile.frame, Int32(index % columns), Int32(index / columns), 1, 1)
            }
        }
        for node in shown { tiles[node.id]?.update(node, focused: session.focused == node.id) }
        UI.setText(keyboardLabel, session.focused.flatMap { session.node($0) }.map { "\($0.name) has the keyboard" } ?? "")
    }
}

// MARK: Focus

/// One machine large, with the keyboard, and every machine that's on in a
/// strip down the left, live. Click one in the strip to make it the large
/// one; it's selected too, for the inspector.
@MainActor
final class NetworkFocusView {
    let widget: Widget
    private let session: NetworkSession
    private weak var studio: NetworkStudioWindow?
    private let strip: Widget
    private let main: Widget
    private let empty: Widget
    private let body: Widget
    private let keyboardLabel: Widget
    private var tile: StationTile?
    private var thumbnails: [UUID: (widget: Widget, picture: Widget, host: EmulatorHost)] = [:]

    init(session: NetworkSession, studio: NetworkStudioWindow) {
        self.session = session
        self.studio = studio
        strip = UI.vbox(spacing: 10)
        strip.setMargins(10)
        main = UI.vbox()
        main.setMargins(12)
        main.expand(horizontally: true, vertically: true)
        empty = NetworkTilesView.noneOn(session)
        let stripScroll = UI.scrolled(strip)
        gtk_widget_set_size_request(stripScroll, 210, -1)
        body = UI.hbox(spacing: 0, [stripScroll, UI.separator(GTK_ORIENTATION_VERTICAL), main])
        body.expand(horizontally: true, vertically: true)
        keyboardLabel = UI.label("", classes: ["dim-label"])
        widget = UI.vbox(spacing: 0, classes: ["network-background"])
        let previous = UI.iconButton("go-previous-symbolic", tooltip: "Show the previous machine", classes: ["flat"]) { [weak self] in
            self?.step(false)
        }
        let next = UI.iconButton("go-next-symbolic", tooltip: "Show the next machine", classes: ["flat"]) { [weak self] in
            self?.step(true)
        }
        let bar = UI.hbox(spacing: 12, [UI.label("Click a machine to bring it here", classes: ["dim-label"]), UI.spacer(), previous, next, keyboardLabel])
        bar.setMargins(top: 6, bottom: 6, start: 12, end: 12)
        for child in [bar, UI.separator(), empty, body] { UI.append(widget, child) }
        observe(self) { [weak self] in self?.update() }
    }

    func close() {
        tile?.close()
        for id in thumbnails.keys { session.thumbnails.hide(id) }
        thumbnails = [:]
    }

    /// The one chosen, if it's on; otherwise the one with the keyboard, or
    /// the first that's on.
    private func mainMachine(among on: [NetworkNode]) -> NetworkNode? {
        for id in [session.project.workspace.focus, session.focused].compactMap({ $0 }) {
            if let node = on.first(where: { $0.id == id }) { return node }
        }
        return on.first
    }

    private func show(_ id: UUID) {
        session.update { $0.workspace.focus = id }
        session.selection = [id]
        session.focus(id)
    }

    private func step(_ forward: Bool) {
        session.focusNext(forward)
        if let id = session.focused { show(id) }
    }

    private func update() {
        let on = session.project.stations.filter { session.isOn($0.id) }
        let chosen = mainMachine(among: on)
        empty.setVisible(chosen == nil)
        body.setVisible(chosen != nil)
        // The strip: each machine that's on, live.
        for (id, thumbnail) in thumbnails where !on.contains(where: { $0.id == id }) || session.controllers[id]?.host !== thumbnail.host {
            session.thumbnails.hide(id)
            gtk_box_remove(strip.cast(), thumbnail.widget)
            thumbnails[id] = nil
        }
        for node in on where thumbnails[node.id] == nil {
            guard let host = session.controllers[node.id]?.host else { continue }
            let picture = gtk_picture_new()!
            gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
            gtk_widget_set_size_request(picture, 180, 135)
            picture.addClass("card-screen")
            let badge = UI.label(node.stationNumber.map(String.init) ?? "–", classes: ["station-badge", "small"], xalign: 0.5)
            let name = UI.label(node.name, classes: ["caption-heading"])
            gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_END)
            let box = UI.vbox(spacing: 5, [picture, UI.hbox(spacing: 6, [badge, name])], classes: ["focus-thumbnail"])
            box.setTooltip("\(node.name): click to bring it here")
            let click = gtk_gesture_click_new()!
            let id = node.id
            onClick(click, "released") { [weak self] _, _, _ in self?.show(id) }
            box.addController(click)
            session.thumbnails.show(node.id, host: host)
            thumbnails[node.id] = (box, picture, host)
            UI.append(strip, box)
            observe(widget: picture) { [weak session] in
                guard let texture = session?.thumbnails.images[id] else { return }
                gtk_picture_set_paintable(picture.cast(), texture)
            }
        }
        for (id, thumbnail) in thumbnails { thumbnail.widget.setClass("showing", id == chosen?.id) }
        // The large one.
        if let chosen, let controller = session.controllers[chosen.id] {
            if tile?.controller !== controller {
                tile?.close()
                UI.removeAll(main)
                let tile = StationTile(session: session, node: chosen, controller: controller, studio: studio)
                self.tile = tile
                gtk_aspect_frame_set_yalign(tile.frame.cast(), 0.5)
                UI.append(main, tile.frame)
                if session.focused != chosen.id { after(0) { [weak self] in self?.session.focus(chosen.id) } }
            }
            tile?.update(chosen, focused: true)
            UI.setText(keyboardLabel, "\(chosen.name) has the keyboard")
        } else {
            tile?.close()
            tile = nil
            UI.removeAll(main)
            UI.setText(keyboardLabel, "")
        }
    }
}
