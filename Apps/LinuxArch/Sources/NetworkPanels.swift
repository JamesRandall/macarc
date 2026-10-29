import ArchimedesCore
import CGtk
import Foundation
import Observation

// The Network Studio's inspector, traffic and Mandelbrot views. (The Mac
// app's.)

// MARK: Inspector

/// The studio's side panel: the network as a whole, or the machine (or
/// clock) selected.
@MainActor
final class NetworkInspectorView {
    let widget: Widget
    private let session: NetworkSession
    weak var studio: NetworkStudioWindow?
    /// What the panel's built for; it's built again when that changes.
    private var shownKey: String?

    init(session: NetworkSession) {
        self.session = session
        widget = UI.vbox(spacing: 18)
        widget.setMargins(16)
        observe(self) { [weak self] in
            guard let self else { return }
            let key = self.key
            guard key != self.shownKey else { return }
            self.shownKey = key
            after(0) { [weak self] in self?.rebuild() }
        }
    }

    /// Everything the panel shows that isn't updated in place.
    private var key: String {
        var parts = [session.selection.map(\.uuidString).sorted().joined(separator: ","), session.project.name,
                     "\(session.project.hasClock)", "\(session.network.pausesOnBreakpoint)", "\(session.project.canvas.snapToGrid)",
                     session.project.problems.map(\.message).joined(separator: ";"), "\(session.controllers.count)",
                     AppSettings.shared.romLibrary.map(\.path).joined(separator: ",")]
        for id in session.selection {
            if let node = session.node(id) {
                parts.append("\(node)")
                parts.append("\(session.isOn(id)) \(session.isSuspended(id))")
            }
        }
        return parts.joined(separator: "|")
    }

    private func rebuild() {
        UI.removeAll(widget)
        if session.selection.count == 1, let node = session.node(session.selection.first!) {
            if node.isMachine { machine(node) } else { clock(node) }
        } else if session.selection.count > 1 {
            selectionSummary()
        } else {
            networkSummary()
        }
    }

    private func section(_ title: String, _ rows: [Widget]) {
        let box = UI.vbox(spacing: 8, [UI.label(title, classes: ["heading"])] + rows)
        UI.append(widget, box)
    }

    private func row(_ label: String, _ value: Widget) -> Widget {
        let title = UI.label(label, classes: ["dim-label"])
        gtk_widget_set_size_request(title, 84, -1)
        title.align(vertical: GTK_ALIGN_CENTER)
        value.expand(horizontally: true)
        return UI.hbox(spacing: 8, [title, value])
    }

    private func valueLabel(_ text: String) -> Widget {
        let label = UI.label(text, wrap: true, selectable: true)
        return label
    }

    private func note(_ text: String) -> Widget {
        UI.label(text, classes: ["caption", "dim-label"], wrap: true)
    }

    private func warning(_ text: String) -> Widget {
        let icon = UI.image(icon: "dialog-warning-symbolic")
        icon.addClass("warning")
        icon.align(vertical: GTK_ALIGN_START)
        let label = UI.label(text, wrap: true)
        label.expand(horizontally: true)
        return UI.hbox(spacing: 6, [icon, label])
    }

    /// A drop-down whose choice calls `changed` (not when it's set up).
    private func picker(_ items: [String], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
        var ready = false
        let dropDown = UI.dropDown(items, selected: max(0, selected)) { index in if ready { changed(index) } }
        ready = true
        return dropDown
    }

    // MARK: The network

    private func networkSummary() {
        let session = session
        let name = UI.entry(placeholder: "Name")
        UI.setText(editable: name, session.project.name)
        onSignal(name, "activate") {
            let text = UI.text(of: name).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { session.update { $0.name = text } }
        }
        let speed = UI.label("", classes: ["numeric"])
        let speedRow = row("Speed", speed)
        observe(widget: speed) {
            let shown = session.status.speed > 0 && !session.controllers.isEmpty
            speedRow.setVisible(shown)
            UI.setText(speed, String(format: "%.0f%% of real time", session.status.speed * 100)
                       + (session.status.threads > 1 ? " on \(session.status.threads) cores" : ""))
        }
        section("Network", [
            row("Name", name),
            row("Machines", valueLabel("\(session.project.stations.count), \(session.controllers.count) on")),
            row("Clock", valueLabel(session.project.hasClock ? "Fitted" : "None")),
            speedRow,
        ])
        let problems = session.project.problems
        section("Problems", problems.isEmpty ? [UI.label("None", classes: ["dim-label"])] : problems.map { warning($0.message) })
        section("Debugging", [
            UI.check("Pause the network at a breakpoint", active: session.network.pausesOnBreakpoint) { on in
                session.network.setPauseOnBreakpoint(on)
            },
            note("When one machine stops in its debugger, the others stop too, so none of them times out waiting for it."),
        ])
        section("Canvas", [
            UI.check("Snap to grid", active: session.project.canvas.snapToGrid) { on in session.update { $0.canvas.snapToGrid = on } },
        ])
        let reveal = UI.button("Show in Files") { [weak self] in revealInFileManager(session.url, parent: self?.studio?.window) }
        reveal.align(horizontal: GTK_ALIGN_START)
        section("File", [reveal, UI.label(session.url.path, classes: ["caption", "dim-label"], wrap: true, selectable: true)])
    }

    private func selectionSummary() {
        let session = session
        let machines = session.selection.compactMap { session.node($0) }.filter(\.isMachine).map(\.id)
        section("\(session.selection.count) Selected", [
            UI.button("Power On") { machines.forEach { session.powerOn($0) } },
            UI.button("Power Off") { machines.forEach { session.powerOff($0) } },
            UI.button("Reset") { machines.forEach { session.reset($0) } },
        ])
    }

    // MARK: A machine

    private func machine(_ node: NetworkNode) {
        let session = session
        let id = node.id
        let controller = session.controllers[id]
        let setup = node.setup ?? StationSetup(model: .a3000)

        let name = UI.entry(placeholder: "Name")
        UI.setText(editable: name, node.name)
        onSignal(name, "activate") { session.rename(id, to: UI.text(of: name)) }
        let number = UI.entry(placeholder: "Station", width: 6)
        UI.setText(editable: number, node.stationNumber.map(String.init) ?? "")
        number.setTooltip("1 to 254; each machine on a network needs its own. RISC OS reads it from CMOS when it starts, so a machine that’s on restarts.")
        let numberProblem = UI.label("", classes: ["caption", "warning"], wrap: true)
        numberProblem.setVisible(false)
        onSignal(number, "activate") {
            guard let value = Int(UI.text(of: number).trimmingCharacters(in: .whitespaces)) else {
                UI.setText(numberProblem, "A station number is a number from 1 to 254")
                numberProblem.setVisible(true)
                return
            }
            if let problem = session.setStationNumber(id, to: value) {
                UI.setText(numberProblem, problem)
                numberProblem.setVisible(true)
                UI.setText(editable: number, session.node(id)?.stationNumber.map(String.init) ?? "")
            } else {
                numberProblem.setVisible(false)
            }
        }
        number.expand(horizontally: false)
        let roles: [NetworkNode.Kind] = [.station, .fileServer]
        let role = picker(roles.map(\.displayName), selected: roles.firstIndex(of: node.kind) ?? 0) { index in
            session.update { $0[id]?.kind = roles[index] }
        }
        var rows = [row("Name", name), row("Station", UI.hbox(spacing: 0, [number])), numberProblem, row("Role", role)]
        if !(node.kind == .fileServer && node.runsLevel4 == true) {
            let startups: [NetworkStartup?] = [nil] + NetworkStartup.allCases.map { Optional($0) }
            let startup = picker(["From its own discs"] + NetworkStartup.allCases.map(\.title),
                                 selected: startups.firstIndex(of: node.startup) ?? 0) { index in
                session.setStartup(id, startups[index])
            }
            startup.setTooltip(startupHelp(node.startup))
            rows.append(row("Starts up", startup))
        }
        section(node.kind.displayName, rows)

        if node.kind == .fileServer {
            var server: [Widget] = []
            let console = UI.label("", classes: ["code-small"], wrap: true)
            let consoleRow = row("Console", console)
            observe(widget: console) {
                let line = session.controllers[id]?.consoleLine
                consoleRow.setVisible(line != nil)
                UI.setText(console, line ?? "")
            }
            server.append(consoleRow)
            if node.runsLevel4 == true {
                server.append(UI.hbox(spacing: 6, [UI.image(icon: "object-select-symbolic"), UI.label("Level 4 File Server set up")]))
                server.append(note("Its hard disc starts the server when the machine does, and the server shares that disc. On the other machines, *I AM SYST at the command line logs on (no password); in the desktop, the Econet icon on the icon bar logs on and opens the server."))
            } else {
                server.append(note(NetworkSession.includedLevel4Disc == nil
                    ? "A file server is an Archimedes running Acorn’s Level 4 File Server, which shares its hard disc with the other machines. Set Up Level 4 makes it one from your Level 4 disc image, with a hard disc that starts it."
                    : "A file server is an Archimedes running Acorn’s Level 4 File Server, which shares its hard disc with the other machines. Set Up Level 4 makes it one: LinuxArch includes Level 4, and makes a hard disc that starts it."))
            }
            let setUp = UI.button(node.runsLevel4 == true ? "Set Up Again" : "Set Up Level 4") { [weak self] in
                session.setUpLevel4(id, parent: self?.studio?.window)
            }
            setUp.setTooltip("Makes a new hard disc for the server with Level 4 on it. The server’s old hard disc is replaced.")
            setUp.align(horizontal: GTK_ALIGN_START)
            server.append(setUp)
            server.append(note("RISC OS 3.10 and 3.11 machines should load !NetUtils (it’s on the server) before copying files of 128K or more: without it, they can be corrupted."))
            section("File Server", server)
        }

        let models = MachineModel.allCases.filter(\.takesEconet)
        let model = picker(models.map(\.rawValue), selected: models.firstIndex(of: setup.model) ?? 0) { index in
            session.setSetup(id, StationSetup(model: models[index], rom: setup.rom))
        }
        let cpus = setup.model.cpuChoices
        let cpu = picker(cpus.map(\.displayName), selected: cpus.firstIndex(of: setup.cpu) ?? 0) { index in
            var s = setup
            s.cpu = cpus[index]
            session.setSetup(id, s)
        }
        let memories = setup.model.ramChoices
        let memory = picker(memories.map(AppSettings.ramLabel), selected: memories.firstIndex(of: setup.ramKB) ?? 0) { index in
            var s = setup
            s.ramKB = memories[index]
            session.setSetup(id, s)
        }
        let roms = AppSettings.shared.romLibrary
        let rom = picker(roms.map(\.version), selected: roms.firstIndex { $0.path == session.romPath(for: setup) } ?? 0) { index in
            var s = setup
            s.rom = roms[index].version
            session.setSetup(id, s)
        }
        let configure = UI.button("Configure Machine…") { [weak self] in self?.studio?.openConfigure(id) }
        configure.setTooltip("The machine’s Configure window: model, processor, monitor, ROM and hard discs")
        configure.align(horizontal: GTK_ALIGN_START)
        section("Machine", [row("Model", model), row("Processor", cpu), row("Memory", memory), row("ROM", rom), configure])

        let power = gtk_switch_new()!
        gtk_switch_set_active(power.cast(), controller != nil ? 1 : 0)
        power.align(horizontal: GTK_ALIGN_START)
        onNotify(power, "active") {
            let on = gtk_switch_get_active(power.cast()) != 0
            guard on != session.isOn(id) else { return }
            if on { session.powerOn(id) } else { session.powerOff(id) }
        }
        var powerRows = [row("On", power)]
        if controller != nil {
            let suspended = UI.check("Suspended", active: session.isSuspended(id)) { on in session.setSuspended(id, on) }
            suspended.setTooltip("It stops where it is while the rest of the network runs on, so other machines waiting for it time out")
            powerRows.append(suspended)
            let cycle = UI.button("Power Cycle") { session.coldBoot(id) }
            cycle.setTooltip("Switch it off and on again")
            powerRows.append(UI.hbox(spacing: 8, [UI.button("Reset") { session.reset(id) }, cycle]))
        }
        section("Power", powerRows)

        let floppy = UI.label(node.discs[0]?.displayName ?? "Empty", classes: node.discs[0] == nil ? ["dim-label"] : [])
        gtk_label_set_ellipsize(floppy.cast(), PANGO_ELLIPSIZE_MIDDLE)
        let insert = UI.iconButton("media-floppy-symbolic", tooltip: "Insert a disc", classes: ["flat"]) { [weak self] in
            session.chooseDisc(for: id, parent: self?.studio?.window)
        }
        let eject = UI.iconButton("media-eject-symbolic", tooltip: "Eject", classes: ["flat"]) { session.eject(id) }
        eject.setSensitive(node.discs[0] != nil)
        floppy.expand(horizontally: true)
        var discs = [row("Floppy", UI.hbox(spacing: 4, [floppy, insert, eject]))]
        for drive in 0..<setup.model.hardDiscSlots {
            let name = UI.label(node.hardDiscs[drive]?.displayName ?? "None", classes: node.hardDiscs[drive] == nil ? ["dim-label"] : [])
            gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_MIDDLE)
            discs.append(row("Hard disc :\(drive + 4)", name))
        }
        discs.append(note("The network keeps its own copies of its discs, so the machines never change your files."))
        section("Discs", discs)

        let open = UI.button("Open Window") { [weak self] in
            if !session.isOn(id) { session.powerOn(id) }
            self?.studio?.openStation(id)
        }
        let debugger = UI.button("Debugger") { [weak self] in self?.studio?.openDebugger(id) }
        debugger.setSensitive(controller != nil)
        UI.append(widget, UI.hbox(spacing: 8, [open, debugger]))
    }

    private func startupHelp(_ startup: NetworkStartup?) -> String {
        switch startup {
        case nil: "It starts from its own discs, as its CMOS says"
        case .netFS: "NetFS is selected at start-up, with the file server on station 254: *I AM (or the Econet icon) logs on. A machine that’s on restarts."
        case .networkBoot: "At power-on NetFS logs on to station 254 as BOOT and runs the boot file in BOOT’s directory, as a school’s network boot did. A machine that’s on restarts."
        case .hardDisc: "It boots from its hard disc (ADFS drive 4), with the file server on station 254 for anything that logs on. A machine that’s on restarts."
        }
    }

    // MARK: The clock

    private func clock(_ node: NetworkNode) {
        let session = session
        let rates = EconetTime.clockRates
        let rate = picker(rates.map(ClockText.rate), selected: rates.firstIndex(of: node.clockRate ?? EconetTime.defaultClockRate) ?? 0) { index in
            session.update { $0[node.id]?.clockRate = rates[index] }
        }
        section("Network Clock", [
            row("Rate", rate),
            note("An Econet carries nothing without a clock: the clock box sets the speed every station sends and receives at."),
        ])
    }
}

// MARK: Traffic

/// The network's traffic: every frame on the line, as the four-way
/// handshake reads them, with what's in them.
@MainActor
final class NetworkTrafficView {
    let widget: Widget
    private let session: NetworkSession
    private let parent: Widget
    private var frames: [EconetFrame] = []
    private var byID: [Int: EconetFrame] = [:]
    /// The frames listed (their ids, in order), as the list's model has them.
    private var listed: [Int] = []
    private var selection: Int?
    private var station: Int?
    private var problemsOnly = false
    private var search = ""
    /// The Distributed Mandelbrot demo's messages, by transaction.
    private var reader = MandelbrotTraffic()
    private var readings: [Int: MandelbrotReading] = [:]
    private var timer: GLibTimer?

    private let model: OpaquePointer
    private let selectionModel: OpaquePointer
    private let listView: Widget
    private let listScroll: Widget
    private let detail: Widget
    private let totals: Widget
    private var recordButton: Widget?

    static let refresh = 0.25
    static let kept = 4096

    init(session: NetworkSession, parent: Widget) {
        self.session = session
        self.parent = parent
        model = gtk_string_list_new(nil)!
        // (The selection and the list view take the references they're
        // given: these are kept, to change them.)
        g_object_ref(model.raw)
        selectionModel = gtk_single_selection_new(model.cast())!
        gtk_single_selection_set_autoselect(selectionModel.cast(), 0)
        gtk_single_selection_set_can_unselect(selectionModel.cast(), 1)
        let factory = gtk_signal_list_item_factory_new()!
        g_object_ref(selectionModel.raw)
        listView = gtk_list_view_new(selectionModel.cast(), factory)!
        listView.addClass("traffic-list")
        listScroll = UI.scrolled(listView, horizontal: GTK_POLICY_AUTOMATIC)
        listScroll.expand(horizontally: true, vertically: true)
        detail = UI.vbox(spacing: 12)
        detail.setMargins(14)
        totals = UI.label("", classes: ["dim-label"])
        widget = UI.vbox(spacing: 0)
        build(factory: factory)
        timer = GLibTimer(interval: Self.refresh) { [weak self] in
            guard let self else { return false }
            self.poll()
            return true
        }
        poll()
        showDetail()
    }

    func close() {
        timer?.invalidate()
    }

    // MARK: Building

    deinit {
        g_object_unref(model.raw)
        g_object_unref(selectionModel.raw)
    }

    private func build(factory: OpaquePointer) {
        let session = session
        // The header: recording, the filters, the totals.
        let record = gtk_toggle_button_new()!
        recordButton = record
        la_set_int(record.raw, "active", session.network.isTracing ? 1 : 0)
        onNotify(record, "active") { [weak self] in
            let on = gtk_toggle_button_get_active(record.cast()) != 0
            session.network.setTracing(on)
            self?.showRecording(on)
        }
        showRecording(session.network.isTracing)
        let clear = UI.iconButton("user-trash-symbolic", tooltip: "Forget the frames recorded so far", classes: ["flat"]) { [weak self] in
            guard let self else { return }
            session.network.clearTrace()
            self.frames = []
            self.byID = [:]
            self.selection = nil
            self.reader = MandelbrotTraffic()
            self.readings = [:]
            self.relist()
            self.showDetail()
        }
        let export = UI.iconButton("document-save-symbolic", tooltip: "Save the frames as JSON (the format MacBeeb uses too, not PCAP)",
                                   classes: ["flat"]) { [weak self] in self?.export() }
        let stations = session.project.stations.compactMap { node in node.stationNumber.map { (node.name, $0) } }
        let stationPicker = UI.dropDown(["All stations"] + stations.map { "\($0.0) (\($0.1))" }) { [weak self] index in
            self?.station = index > 0 ? stations[index - 1].1 : nil
            self?.relist()
        }
        let problems = UI.check("Problems only", active: false) { [weak self] on in
            self?.problemsOnly = on
            self?.relist()
        }
        let searchEntry = UI.entry(placeholder: "Search bytes or text", width: 18)
        onSignal(searchEntry, "changed") { [weak self] in
            self?.search = UI.text(of: searchEntry)
            self?.relist()
        }
        let header = UI.hbox(spacing: 12, [record, clear, export, UI.separator(GTK_ORIENTATION_VERTICAL), stationPicker, problems, searchEntry, UI.spacer(), totals])
        header.setMargins(top: 6, bottom: 6, start: 12, end: 12)
        totals.setTooltip("Counted on the line since the network opened")
        observe(widget: totals) {
            let traffic = session.status.traffic
            let frames = traffic.values.reduce(0) { $0 + $1.frames }
            let collisions = traffic.values.reduce(0) { $0 + $1.collisions }
            UI.setText(self.totals, "\(frames) frames · \(collisions) collided")
        }

        // The table: a heading, and the rows (made as they're shown).
        let heading = Self.makeRow()
        for (label, text) in zip(Self.cells(heading), ["Time", "From", "To", "Frame", "#"]) { UI.setText(label, text) }
        heading.addClass("heading")
        heading.setMargins(top: 4, bottom: 4, start: 12, end: 12)
        let setup: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, item, _ in
            MainActor.assumeIsolated {
                let row = NetworkTrafficView.makeRow()
                row.setMargins(start: 6, end: 6)
                gtk_list_item_set_child(OpaquePointer(item), row)
            }
        }
        let bind: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, item, data in
            let view = Unmanaged<NetworkTrafficView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let row = gtk_list_item_get_child(OpaquePointer(item)), let object = gtk_list_item_get_item(OpaquePointer(item)),
                      let text = String(gBorrowed: la_string_object_text(object.raw)), let id = Int(text),
                      let frame = view.byID[id] else { return }
                view.show(frame, in: row)
            }
        }
        la_signal_connect(factory.raw, "setup", unsafeBitCast(setup, to: GCallback.self), nil, nil, 0)
        la_signal_connect(factory.raw, "bind", unsafeBitCast(bind, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        onNotify(selectionModel, "selected") { [weak self] in
            guard let self else { return }
            let index = gtk_single_selection_get_selected(self.selectionModel.cast())
            self.selection = index != GTK_INVALID_LIST_POSITION && Int(index) < self.listed.count ? self.listed[Int(index)] : nil
            self.showDetail()
            // Show who's involved on the canvas too.
            guard let id = self.selection, let frame = self.byID[id] else { return }
            let stations = [frame.transmitter, frame.destinationStation].compactMap { $0 }
            session.selection = Set(session.project.nodes.filter { node in
                node.stationNumber.map { stations.contains(UInt8(clamping: $0)) } ?? false
            }.map(\.id))
        }
        let table = UI.vbox(spacing: 0, [heading, UI.separator(), listScroll])
        gtk_widget_set_size_request(table, 420, -1)
        let paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(paned.cast(), table)
        let detailScroll = UI.scrolled(detail)
        gtk_widget_set_size_request(detailScroll, 300, -1)
        gtk_paned_set_end_child(paned.cast(), detailScroll)
        gtk_paned_set_shrink_end_child(paned.cast(), 0)
        gtk_paned_set_resize_end_child(paned.cast(), 0)
        paned.expand(horizontally: true, vertically: true)
        UI.append(widget, header)
        UI.append(widget, UI.separator())
        UI.append(widget, paned)
    }

    private func showRecording(_ on: Bool) {
        guard let recordButton else { return }
        let content = adw_button_content_new()!
        adw_button_content_set_icon_name(content.cast(), on ? "media-record-symbolic" : "media-playback-pause-symbolic")
        adw_button_content_set_label(content.cast(), on ? "Recording" : "Paused")
        gtk_button_set_child(recordButton.cast(), content)
        recordButton.setTooltip("Record frames as they cross the line")
    }

    private static func makeRow() -> Widget {
        let widths: [Int32] = [80, 100, 100, -1, 40]
        let cells = widths.map { width -> Widget in
            let label = UI.label("", classes: ["code-small"])
            gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(label.cast(), 1)
            if width > 0 { gtk_widget_set_size_request(label, width, -1) } else { label.expand(horizontally: true) }
            return label
        }
        return UI.hbox(spacing: 8, cells)
    }

    private static func cells(_ row: Widget) -> [Widget] {
        var cells: [Widget] = []
        var child = gtk_widget_get_first_child(row)
        while let widget = child {
            cells.append(widget)
            child = gtk_widget_get_next_sibling(widget)
        }
        return cells
    }

    private func show(_ frame: EconetFrame, in row: Widget) {
        let cells = Self.cells(row)
        guard cells.count == 5 else { return }
        UI.setText(cells[0], String(format: "%.3f s", Double(frame.start) / Double(EconetTime.ticksPerSecond)))
        UI.setText(cells[1], name(frame.transmitter))
        UI.setText(cells[2], frame.destinationStation.map(name) ?? "–")
        UI.setText(cells[3], symbol(frame) + " " + summary(frame))
        cells[3].setClass("warning", frame.status != .valid)
        UI.setText(cells[4], frame.transaction.map(String.init) ?? "")
    }

    // MARK: Following the line

    private func poll() {
        let newer = session.network.frames(after: frames.last?.id)
        guard !newer.isEmpty else { return }
        for frame in newer {
            if let reading = reader.read(frame), let transaction = frame.transaction { readings[transaction] = reading }
            byID[frame.id] = frame
        }
        if readings.count > 8192, let oldest = frames.first?.transaction {
            readings = readings.filter { $0.key >= oldest }
        }
        frames.append(contentsOf: newer)
        var dropped: [EconetFrame] = []
        if frames.count > Self.kept {
            dropped = Array(frames.prefix(frames.count - Self.kept))
            frames.removeFirst(frames.count - Self.kept)
            for frame in dropped { byID[frame.id] = nil }
        }
        // Listed rows: the dropped go from the top, the new matching ones
        // on at the end (without disturbing the rest, or the selection).
        let vadjustment = gtk_scrolled_window_get_vadjustment(listScroll.cast())
        let atEnd = gtk_adjustment_get_value(vadjustment) + gtk_adjustment_get_page_size(vadjustment) >= gtk_adjustment_get_upper(vadjustment) - 4
        let gone = Set(dropped.map(\.id))
        let leading = listed.prefix { gone.contains($0) }.count
        if leading > 0 {
            gtk_string_list_splice(model.cast(), 0, guint(leading), nil)
            listed.removeFirst(leading)
        }
        let additions = newer.filter(matches).map(\.id)
        if !additions.isEmpty {
            var strings = additions.map { strdup(String($0)) } + [nil]
            defer { strings.forEach { free($0) } }
            strings.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { pointers in
                    gtk_string_list_splice(model.cast(), guint(listed.count), 0, pointers.baseAddress)
                }
            }
            listed += additions
        }
        // Following the newest, if that's where it was.
        if atEnd, !additions.isEmpty {
            after(0.05) { [weak self] in
                guard let self else { return }
                let adjustment = gtk_scrolled_window_get_vadjustment(self.listScroll.cast())
                gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
            }
        }
        if selection == nil && frames.count == newer.count { showDetail() }
    }

    /// The frames listed again, after a filter's changed.
    private func relist() {
        let shown = frames.filter(matches).map(\.id)
        var strings = shown.map { strdup(String($0)) } + [nil]
        defer { strings.forEach { free($0) } }
        strings.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { pointers in
                gtk_string_list_splice(model.cast(), 0, guint(listed.count), pointers.baseAddress)
            }
        }
        listed = shown
        if let selection, let index = listed.firstIndex(of: selection) {
            gtk_single_selection_set_selected(selectionModel.cast(), guint(index))
        } else {
            selection = nil
            showDetail()
        }
    }

    private func matches(_ frame: EconetFrame) -> Bool {
        if let station, frame.transmitter != UInt8(clamping: station) && frame.destinationStation != UInt8(clamping: station) {
            return false
        }
        if problemsOnly && frame.status == .valid { return false }
        if !search.isEmpty {
            let text = search.lowercased()
            let bytes = String(decoding: frame.bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self).lowercased()
            let hex = frame.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            if !summary(frame).lowercased().contains(text) && !bytes.contains(text) && !hex.contains(text) { return false }
        }
        return true
    }

    /// The demo's message in a data frame, if it's one.
    private func reading(_ frame: EconetFrame) -> MandelbrotReading? {
        guard frame.kind == .data, let transaction = frame.transaction else { return nil }
        return readings[transaction]
    }

    /// The frame, and what's in it where that's known.
    private func summary(_ frame: EconetFrame) -> String {
        reading(frame).map { frame.summary + " · " + $0.summary } ?? frame.summary
    }

    /// What a frame's port is for: the demo's name, if its data was the demo's.
    private func portName(_ frame: EconetFrame) -> String? {
        guard let port = frame.port else { return nil }
        if let transaction = frame.transaction, readings[transaction] != nil, let name = MandelbrotProtocol.portName(port) {
            return name
        }
        return EconetFrame.portName(port)
    }

    private func name(_ station: UInt8) -> String {
        if station == 255 { return "Everyone" }
        return session.project.nodes.first { $0.stationNumber == Int(station) }?.name ?? "Station \(station)"
    }

    private func symbol(_ frame: EconetFrame) -> String {
        switch frame.status {
        case .collided: return "⚠"
        case .aborted: return "✕"
        case .valid:
            switch frame.kind {
            case .scout: return "→"
            case .acknowledgement: return "✓"
            case .data: return "▤"
            case .broadcast: return "⇶"
            case .unknown: return "?"
            }
        }
    }

    // MARK: Detail

    private func showDetail() {
        UI.removeAll(detail)
        guard let id = selection, let frame = byID[id] else {
            let page = adw_status_page_new()!
            adw_status_page_set_icon_name(page.cast(), "network-transmit-receive-symbolic")
            adw_status_page_set_title(page.cast(), "No Frame Selected")
            adw_status_page_set_description(page.cast(), frames.isEmpty
                ? "Nothing’s crossed the line yet. Try *I AM on a machine, or open the Econet icon in the Filer."
                : "Choose a frame to see what’s in it.")
            page.expand(vertically: true)
            UI.append(detail, page)
            return
        }
        UI.append(detail, UI.label(frame.summary, classes: ["heading"], wrap: true))
        var rows: [(String, String)] = [("From", name(frame.transmitter) + " (\(frame.transmitter))")]
        if let to = frame.destinationStation { rows.append(("To", name(to) + " (\(to)), network \(frame.destinationNetwork ?? 0)")) }
        rows.append(("Status", explanation(frame.status)))
        rows.append(("Length", "\(frame.bytes.count) bytes, \(String(format: "%.2f ms", Double(frame.end - frame.start) / Double(EconetTime.ticksPerSecond / 1000))) on the line"))
        if let transaction = frame.transaction { rows.append(("Transaction", "#\(transaction): " + kindText(frame.kind))) }
        if let port = portName(frame) { rows.append(("Port", port)) }
        UI.append(detail, grid(rows))
        if let reading = reading(frame) {
            UI.append(detail, UI.separator())
            UI.append(detail, UI.label(MandelbrotProtocol.portName(reading.port) ?? "Mandelbrot", classes: ["heading"]))
            switch reading.message {
            case .success(let message):
                UI.append(detail, UI.label(message.summary(to: reading.to), wrap: true, selectable: true))
                UI.append(detail, grid(message.fields.map { ($0.label, $0.value) }))
            case .failure(let error):
                UI.append(detail, UI.label("Not a Distributed Mandelbrot message: \(error.description)", classes: ["warning"], wrap: true))
            }
        }
        UI.append(detail, UI.label(Self.dump(frame.bytes), classes: ["code-small"], selectable: true))
        UI.append(detail, UI.label("Bytes 0-3 are who it’s to and from (station, network); a scout’s byte 4 is the control byte and byte 5 the port. The check bytes aren’t shown.",
                                   classes: ["caption", "dim-label"], wrap: true))
    }

    private func grid(_ rows: [(String, String)]) -> Widget {
        let grid = gtk_grid_new()!
        gtk_grid_set_column_spacing(grid.cast(), 10)
        gtk_grid_set_row_spacing(grid.cast(), 4)
        for (index, (label, value)) in rows.enumerated() {
            let name = UI.label(label, classes: ["dim-label"])
            name.align(vertical: GTK_ALIGN_START)
            let text = UI.label(value, wrap: true, selectable: true)
            text.expand(horizontally: true)
            gtk_grid_attach(grid.cast(), name, 0, Int32(index), 1, 1)
            gtk_grid_attach(grid.cast(), text, 1, Int32(index), 1, 1)
        }
        return grid
    }

    /// Sixteen bytes a line: offset, hex, then the printable ones.
    static func dump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { start in
            let line = bytes[start..<min(start + 16, bytes.count)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let text = String(line.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04X  ", start) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + text
        }.joined(separator: "\n")
    }

    private func explanation(_ status: EconetFrame.Status) -> String {
        switch status {
        case .valid: "Complete: closed with its check bytes"
        case .collided: "Spoiled: another station was transmitting at the same time"
        case .aborted: "Abandoned part way: the transmitter stopped or ran dry"
        }
    }

    private func kindText(_ kind: EconetFrame.Kind) -> String {
        switch kind {
        case .scout: "the scout, asking to send"
        case .acknowledgement: "an acknowledgement"
        case .data: "the data"
        case .broadcast: "a broadcast"
        case .unknown: "not recognised"
        }
    }

    private func export() {
        let frames = frames
        let name = session.project.name
        FileDialogs.save(parent: parent, title: "Export Traffic", name: "\(name) traffic.json",
                         filters: [.init(name: "JSON", suffixes: ["json"])]) { [weak self] url in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let export = TrafficExport(network: name, cyclesPerSecond: Int(EconetTime.ticksPerSecond), frames: frames)
                try encoder.encode(export).write(to: url, options: .atomic)
            } catch {
                Alerts.show(error, parent: self?.parent)
            }
        }
    }
}

/// A traffic capture as saved: MacBeeb's JSON format, so either app's
/// captures read the same (times in `cyclesPerSecond`: MacArch's are 24 MHz
/// ticks, MacBeeb's 2 MHz cycles).
struct TrafficExport: Codable {
    var format = "MacBeeb Econet trace 1"
    var network: String
    /// The frames' times are in these.
    var cyclesPerSecond: Int
    var frames: [EconetFrame]
}

// MARK: Mandelbrot

/// Follows the network's trace for the Distributed Mandelbrot demo, for
/// the studio's Mandelbrot view. It reads the frames from when it's first
/// shown until the studio closes, so switching views doesn't lose a
/// render. It only watches: what's drawn is what the workers sent.
@MainActor @Observable
final class MandelbrotFeed {
    private(set) var observer = MandelbrotObserver()
    @ObservationIgnored private weak var session: NetworkSession?
    @ObservationIgnored private var lastFrame: Int?
    @ObservationIgnored private var timer: GLibTimer?
    /// Tracing was off, and the view turned it on.
    @ObservationIgnored private var turnedTracingOn = false

    static let refresh = 0.25

    func start(_ session: NetworkSession) {
        self.session = session
        let network = session.network
        if !network.isTracing {
            network.setTracing(true)
            turnedTracingOn = true
        }
        guard timer == nil else { return }
        poll()
        timer = GLibTimer(interval: Self.refresh) { [weak self] in
            guard let self else { return false }
            self.poll()
            return true
        }
    }

    /// The view's gone: put tracing back as it was.
    func hidden() {
        if turnedTracingOn {
            session?.network.setTracing(false)
            turnedTracingOn = false
        }
    }

    /// Forget what's been seen, and carry on from here.
    func reset() {
        observer = MandelbrotObserver()
        picture = nil
    }

    private func poll() {
        guard let session else { return }
        let newer = session.network.frames(after: lastFrame)
        var observer = observer
        if !newer.isEmpty {
            observer.observe(newer)
            lastFrame = newer.last?.id
        }
        observer.advance(to: session.status.ticks)
        // Only publish a change (it's a big value).
        if observer.now != self.observer.now || !newer.isEmpty { self.observer = observer }
    }

    // MARK: The picture

    @ObservationIgnored private var picture: (key: PictureKey, texture: OpaquePointer)?

    private struct PictureKey: Equatable {
        var run: UInt32?
        var accepted: Int
        var authentic: Bool
        var max: Int
    }

    /// The accepted tiles' counts as colours; missing pixels are clear.
    func image(authentic: Bool) -> OpaquePointer? {
        let key = PictureKey(run: observer.runId, accepted: observer.tilesCompleted, authentic: authentic, max: observer.maxIterations)
        if let picture, picture.key == key { return picture.texture }
        let width = MandelbrotProtocol.imageWidth, height = MandelbrotProtocol.imageHeight
        let observer = self.observer
        let max = observer.maxIterations
        let table = (0 ... 255).map { n in authentic ? Self.mode12(n, max: max) : Self.gradient(n, max: max) }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in 0 ..< width * height where observer.covered[i] {
            let (r, g, b) = table[Int(observer.image[i])]
            pixels[i] = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
        guard let texture = Pixels(width: width, height: height, pixels: pixels).texture() else { return nil }
        if let old = picture?.texture { g_object_unref(old.raw) }
        picture = (key, texture)
        return texture
    }

    /// The coordinator's fourteen bands (shared.s's s_colours, before
    /// they cycle), and black inside the set.
    static let bands: [(UInt8, UInt8, UInt8)] = [
        (0, 32, 128), (0, 80, 192), (0, 144, 224), (0, 208, 240), (128, 240, 255), (240, 255, 224), (255, 240, 128),
        (255, 200, 0), (255, 144, 0), (240, 80, 0), (208, 32, 32), (176, 0, 96), (112, 0, 144), (48, 0, 128),
    ]

    /// As the coordinator shows it: colour 0 (black) if `n == max`,
    /// otherwise band `1 + (n - 1) mod 14`.
    static func mode12(_ n: Int, max: Int) -> (UInt8, UInt8, UInt8) {
        let colour = MandelbrotProtocol.colour(n, max: max)
        return colour == 0 ? (0, 0, 0) : bands[colour - 1]
    }

    /// Smoother: the count, on a log scale, through deep blue, white and
    /// orange; the set itself is black.
    static func gradient(_ n: Int, max: Int) -> (UInt8, UInt8, UInt8) {
        guard n < max, max > 1 else { return (0, 0, 0) }
        let t = log(Double(Swift.max(n, 1))) / log(Double(max))
        let stops: [(Double, Double, Double, Double)] = [
            (0, 0, 7, 100), (0.16, 32, 107, 203), (0.42, 237, 255, 255), (0.6425, 255, 170, 0), (0.8575, 120, 20, 0), (1, 40, 0, 10),
        ]
        let upper = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
        let lower = Swift.max(upper - 1, 0)
        let (a, b) = (stops[lower], stops[upper])
        let f = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
        func mix(_ x: Double, _ y: Double) -> UInt8 { UInt8(clamping: Int((x + (y - x) * f).rounded())) }
        return (mix(a.1, b.1), mix(a.2, b.2), mix(a.3, b.3))
    }
}

/// The Distributed Mandelbrot demo, as its frames show it: the picture
/// from the tiles the coordinator accepted, the tiles out with workers,
/// and what each worker's done.
@MainActor
final class NetworkMandelbrotView {
    let widget: Widget
    private let session: NetworkSession
    private let feed: MandelbrotFeed
    private var authentic = Preferences.standard.object(forKey: "mandelbrotAuthenticPalette") as? Bool ?? true
    private var showsInFlight = Preferences.standard.object(forKey: "mandelbrotShowsInFlight") as? Bool ?? true
    private let picture: Widget
    private let inFlight: Widget
    private let sidebar: Widget
    private let empty: Widget
    private let body: Widget
    private let progress: Widget

    /// MODE 12's pixels are twice as tall as they're wide.
    static let aspect = Double(MandelbrotProtocol.imageWidth) / Double(MandelbrotProtocol.imageHeight * 2)
    private static let palette: [(Double, Double, Double)] = [
        (1, 0.47, 0), (0.18, 0.76, 0.49), (0.95, 0.4, 0.6), (0.57, 0.25, 0.67), (0.13, 0.63, 0.62), (0.88, 0.11, 0.14),
        (0.96, 0.83, 0.18), (0.4, 0.85, 0.7), (0.3, 0.3, 0.75), (0.6, 0.45, 0.3),
    ]

    init(session: NetworkSession, feed: MandelbrotFeed) {
        self.session = session
        self.feed = feed
        picture = gtk_picture_new()!
        gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
        inFlight = gtk_drawing_area_new()!
        sidebar = UI.vbox(spacing: 18)
        sidebar.setMargins(16)
        progress = UI.label("", classes: ["dim-label", "numeric"])
        let emptyPage = adw_status_page_new()!
        adw_status_page_set_icon_name(emptyPage.cast(), "view-grid-symbolic")
        adw_status_page_set_title(emptyPage.cast(), "No Mandelbrot Traffic Yet")
        empty = emptyPage
        empty.expand(horizontally: true, vertically: true)
        body = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        widget = UI.vbox(spacing: 0)
        build()
        feed.start(session)
        observe(self) { [weak self] in self?.update() }
    }

    func close() {
        feed.hidden()
    }

    private func build() {
        let colours = UI.check("Coordinator’s colours", active: authentic) { [weak self] on in
            self?.authentic = on
            Preferences.standard.set(on, forKey: "mandelbrotAuthenticPalette")
            self?.update()
        }
        colours.setTooltip("The coordinator’s own fourteen bands, or a smoother gradient from the same counts")
        let flight = UI.check("Tiles in flight", active: showsInFlight) { [weak self] on in
            self?.showsInFlight = on
            Preferences.standard.set(on, forKey: "mandelbrotShowsInFlight")
            self?.update()
        }
        flight.setTooltip("Outline the tiles given out and not yet accepted, in their worker’s colour")
        let clear = UI.iconButton("user-trash-symbolic", tooltip: "Forget what’s been seen, and follow from here", classes: ["flat"]) { [weak self] in
            self?.feed.reset()
        }
        let header = UI.hbox(spacing: 14, [colours, flight, UI.spacer(), progress, clear])
        header.setMargins(top: 6, bottom: 6, start: 12, end: 12)

        let draw: GtkDrawingAreaDrawFunc = { _, cairo, width, height, data in
            let view = Unmanaged<NetworkMandelbrotView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { view.drawInFlight(cairo!, Double(width), Double(height)) }
        }
        gtk_drawing_area_set_draw_func(inFlight.cast(), draw, Unmanaged.passUnretained(self).toOpaque(), nil)
        let stack = gtk_overlay_new()!
        let backdrop = UI.box(GTK_ORIENTATION_VERTICAL, classes: ["mandelbrot-backdrop"])
        gtk_overlay_set_child(stack.cast(), backdrop)
        gtk_overlay_add_overlay(stack.cast(), picture)
        gtk_widget_set_can_target(inFlight, 0)
        gtk_overlay_add_overlay(stack.cast(), inFlight)
        let frame = gtk_aspect_frame_new(0.5, 0.5, Float(Self.aspect), 0)!
        gtk_aspect_frame_set_child(frame.cast(), stack)
        frame.setMargins(12)
        frame.expand(horizontally: true, vertically: true)
        gtk_widget_set_size_request(frame, 320, -1)
        gtk_paned_set_start_child(body.cast(), frame)
        let sidebarScroll = UI.scrolled(sidebar)
        gtk_widget_set_size_request(sidebarScroll, 280, -1)
        gtk_paned_set_end_child(body.cast(), sidebarScroll)
        gtk_paned_set_shrink_end_child(body.cast(), 0)
        gtk_paned_set_resize_end_child(body.cast(), 0)
        body.expand(horizontally: true, vertically: true)
        UI.append(widget, header)
        UI.append(widget, UI.separator())
        UI.append(widget, empty)
        UI.append(widget, body)
    }

    private var observer: MandelbrotObserver { feed.observer }

    /// Each worker's colour, by station, in order.
    private var workerColours: [UInt8: (Double, Double, Double)] {
        Dictionary(uniqueKeysWithValues: observer.sortedWorkers.enumerated().map { ($1.station, Self.palette[$0 % Self.palette.count]) })
    }

    private func update() {
        let observer = self.observer
        empty.setVisible(observer.isEmpty)
        body.setVisible(!observer.isEmpty)
        var text = "When the Distributed Mandelbrot demo runs on this network, its picture builds up here from the frames on the line. "
        if session.project.demo == .distributedMandelbrot, let server = session.project.nodes.first(where: { $0.kind == .fileServer }),
           server.runsLevel4 != true {
            text += "First set up the file server (select it, then Set Up Level 4): the workers then start again and boot from it. "
        }
        adw_status_page_set_description(empty.cast(), text + "The workers boot from the file server into Worker and wait; the Guide boots and logs on. On the Guide, type Mandel.")
        var progressText = "\(observer.tilesCompleted) of \(MandelbrotProtocol.tileCount) tiles"
        if let seconds = observer.elapsedSeconds { progressText += String(format: " · %.1f s", seconds) }
        if observer.completeSeen { progressText += " · Complete" }
        UI.setText(progress, observer.isEmpty ? "" : progressText)
        if let texture = feed.image(authentic: authentic) { gtk_picture_set_paintable(picture.cast(), texture) }
        inFlight.setVisible(showsInFlight)
        gtk_widget_queue_draw(inFlight)
        showSidebar()
    }

    private func drawInFlight(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let sx = width / Double(MandelbrotProtocol.imageWidth)
        let sy = height / Double(MandelbrotProtocol.imageHeight)
        let colours = workerColours
        for assignment in observer.inFlight {
            let (r, g, b) = colours[assignment.station] ?? (1, 1, 1)
            let x = Double(assignment.x) * sx, y = Double(assignment.y) * sy
            let w = Double(assignment.width) * sx, h = Double(assignment.height) * sy
            cairo_set_source_rgba(cr, r, g, b, 0.25)
            cairo_rectangle(cr, x, y, w, h)
            cairo_fill(cr)
            cairo_set_source_rgba(cr, r, g, b, 1)
            cairo_set_line_width(cr, 2)
            cairo_rectangle(cr, x + 1, y + 1, w - 2, h - 2)
            cairo_stroke(cr)
        }
    }

    private func showSidebar() {
        let observer = self.observer
        UI.removeAll(sidebar)
        func section(_ title: String, _ rows: [Widget]) {
            UI.append(sidebar, UI.vbox(spacing: 8, [UI.label(title, classes: ["heading"])] + rows))
        }
        func row(_ label: String, _ value: String) -> Widget {
            let name = UI.label(label, classes: ["dim-label"])
            gtk_widget_set_size_request(name, 90, -1)
            let text = UI.label(value, wrap: true)
            text.expand(horizontally: true)
            return UI.hbox(spacing: 8, [name, text])
        }
        let bar = gtk_progress_bar_new()!
        gtk_progress_bar_set_fraction(bar.cast(), Double(observer.tilesCompleted) / Double(max(1, MandelbrotProtocol.tileCount)))
        var render = [bar, row("Accepted", "\(observer.tilesCompleted) of \(MandelbrotProtocol.tileCount) tiles"),
                      row("Received", "\(observer.received.count) result\(observer.received.count == 1 ? "" : "s")"),
                      row("In flight", "\(observer.inFlight.count)")]
        if let seconds = observer.elapsedSeconds {
            render.append(row("Time", String(format: "%.1f s emulated", seconds) + (observer.completeSeen ? ", complete" : "")))
        }
        if let coordinator = observer.coordinator { render.append(row("Coordinator", name(coordinator))) }
        if let run = observer.runId { render.append(row("Run", String(format: "&%08X", run))) }
        render.append(row("Iterations", "At most \(observer.maxIterations)"))
        section("Render", render)
        var workers: [Widget] = observer.workers.isEmpty ? [UI.label("None seen yet", classes: ["dim-label"])] : []
        for worker in observer.sortedWorkers {
            let swatch = UI.box(GTK_ORIENTATION_HORIZONTAL, classes: ["swatch"])
            gtk_widget_set_size_request(swatch, 12, 12)
            swatch.align(vertical: GTK_ALIGN_CENTER)
            if let index = observer.sortedWorkers.firstIndex(where: { $0.station == worker.station }) {
                swatch.addClass("worker-\(index % Self.palette.count)")
            }
            let title = UI.label(name(worker.station), classes: ["heading"])
            title.expand(horizontally: true)
            let state = UI.label(stateText(worker), classes: worker.state == .unresponsive ? ["caption", "warning"] : ["caption", "dim-label"])
            var lines = [UI.hbox(spacing: 6, [swatch, title, state]),
                         UI.label("\(worker.tiles) tiles · \(worker.pixels) pixels · \(worker.iterations) iterations · \(worker.bytes) bytes",
                                  classes: ["caption", "dim-label", "numeric"], wrap: true)]
            if worker.duplicates > 0 || worker.stale > 0 {
                lines.append(UI.label("\(worker.duplicates) duplicate, \(worker.stale) stale", classes: ["caption", "dim-label"]))
            }
            workers.append(UI.vbox(spacing: 3, lines))
        }
        section("Workers", workers)
        if observer.missedFrames > 0 || observer.malformed > 0 {
            var gaps: [Widget] = []
            if observer.missedFrames > 0 {
                gaps.append(UI.label("\(observer.missedFrames) frames went from the trace before they were read, so some tiles may be missing.",
                                     classes: ["warning"], wrap: true))
            }
            if observer.malformed > 0 {
                gaps.append(UI.label("\(observer.malformed) frames on the demo’s ports weren’t its messages.", wrap: true))
            }
            section("Gaps", gaps)
        }
        UI.append(sidebar, UI.label("Drawn only from the counts the workers sent, for the tiles the coordinator accepted. Nothing is worked out here.",
                                    classes: ["caption", "dim-label"], wrap: true))
    }

    private func stateText(_ worker: MandelbrotObserver.Worker) -> String {
        switch worker.state {
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .computing: return worker.current.map { "Computing tile \($0.tile)" } ?? "Computing"
        case .sending: return worker.current.map { "Sending tile \($0.tile)" } ?? "Sending"
        case .unresponsive: return "Unresponsive"
        }
    }

    private func name(_ station: UInt8) -> String {
        let node = session.project.nodes.first { $0.stationNumber == Int(station) }
        return node.map { "\($0.name) (\(station))" } ?? "Station \(station)"
    }
}
