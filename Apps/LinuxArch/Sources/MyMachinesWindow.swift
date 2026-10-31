import ArchimedesCore
import CGtk
import Foundation

/// My Machines (the main menu, or Ctrl+Shift+Alt+K): the Archimedes saved
/// with names, to start again as they were left. Machine ▸ Save to My
/// Machines… adds them; Create Machine… sets one up from scratch; Import
/// Machine… adds a machine configuration file. (The Mac app's
/// MyMachinesView.)
@MainActor
final class MyMachinesWindow {
    static let title = "My Machines"
    private(set) static var current: MyMachinesWindow?

    /// Opens My Machines, or brings it to the front.
    @discardableResult
    static func show() -> MyMachinesWindow {
        if let current {
            current.present()
            return current
        }
        let window = MyMachinesWindow()
        current = window
        window.present()
        return window
    }

    /// A machine window opened or closed: which entries are running changed.
    static func machinesChanged() {
        current?.showTiles()
    }

    let window: Widget
    private let machines = MyMachines.shared
    private let stack: Widget
    private let grid: Widget
    private let startButton: Widget
    private var tileIDs: [UUID] = []
    /// The selected entry.
    private var selection: UUID? {
        didSet { updateStart() }
    }
    /// The tiles are being replaced: their selection isn't the user's.
    private var rebuilding = false
    private var createDialog: CreateMachineDialog?

    private init() {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_title(window.cast(), Self.title)
        gtk_window_set_default_size(window.cast(), 980, 700)
        gtk_widget_set_size_request(window, 360, 400)
        stack = gtk_stack_new()!
        grid = gtk_flow_box_new()!
        startButton = UI.button("_Start", classes: ["suggested-action"]) {}
        build()
        observe(self) { [weak self] in
            guard let self else { return }
            _ = (self.machines.entries, self.machines.revision)
            self.showTiles()
        }
        onSignalReturning(window, "close-request") { [weak self] in
            self?.createDialog?.close()
            Self.current = nil
            return false
        }
    }

    func present() {
        machines.reload()
        gtk_window_present(window.cast())
    }

    // MARK: Building

    private func build() {
        let header = adw_header_bar_new()!

        // The heading, with what to do beside it.
        let text = UI.vbox(spacing: 4, [
            UI.label(Self.title, classes: ["shelf-title"]),
            UI.label("Archimedes kept as you left them: the model, processor, memory, monitor, ROM, hard discs and RISC OS’s settings. Double-click one to start it.",
                     classes: ["shelf-subtitle", "dim-label"], wrap: true),
        ])
        text.expand(horizontally: true)
        let create = UI.button("_Create Machine…") { [weak self] in self?.showCreate() }
        create.setTooltip("Set up a new machine: its model, processor, memory, monitor, ROM and hard discs")
        let importButton = UI.button("_Import Machine…") { [weak self] in self?.chooseImport() }
        importButton.setTooltip("Add a machine configuration file (as Export Machine Configuration writes) to My Machines")
        onSignal(startButton, "clicked") { [weak self] in
            guard let self, let id = self.selection else { return }
            self.start(id)
        }
        let buttons = UI.hbox(spacing: 8, [create, importButton, startButton])
        buttons.align(vertical: GTK_ALIGN_CENTER)
        let heading = UI.hbox(spacing: 16, [text, buttons])

        gtk_flow_box_set_selection_mode(grid.cast(), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_activate_on_single_click(grid.cast(), 0)
        gtk_flow_box_set_homogeneous(grid.cast(), 1)
        gtk_flow_box_set_column_spacing(grid.cast(), 24)
        gtk_flow_box_set_row_spacing(grid.cast(), 24)
        gtk_flow_box_set_max_children_per_line(grid.cast(), 8)
        grid.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START)
        grid.addClass("shelf")
        onSignal(grid, "selected-children-changed") { [weak self] in
            guard let self, !self.rebuilding else { return }
            let selected = gtk_flow_box_get_selected_children(self.grid.cast())
            let child = selected?.pointee.data
            g_list_free(selected)
            let index = child.map { Int(gtk_flow_box_child_get_index($0.cast())) }
            self.selection = index.flatMap { self.tileIDs.indices.contains($0) ? self.tileIDs[$0] : nil }
        }
        let activated: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, child, data in
            let window = Unmanaged<MyMachinesWindow>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let child else { return }
                let index = Int(gtk_flow_box_child_get_index(child.cast()))
                if window.tileIDs.indices.contains(index) { window.start(window.tileIDs[index]) }
            }
        }
        la_signal_connect(grid.raw, "child-activated", unsafeBitCast(activated, to: GCallback.self),
                          Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        let shelf = UI.vbox(spacing: 24, [heading, grid])
        shelf.setMargins(28)

        // Nothing saved yet.
        let empty = adw_status_page_new()!
        adw_status_page_set_icon_name(empty.cast(), "computer-symbolic")
        adw_status_page_set_title(empty.cast(), "No Machines Yet")
        adw_status_page_set_description(empty.cast(),
            "Create one here, or set an Archimedes up as you like it and choose Machine ▸ Save to My Machines… to keep it with a name. Or import a machine configuration file.")
        let emptyCreate = UI.button("Create Machine…", classes: ["suggested-action", "pill"]) { [weak self] in self?.showCreate() }
        let emptyImport = UI.button("Import Machine…", classes: ["pill"]) { [weak self] in self?.chooseImport() }
        let emptyButtons = UI.hbox(spacing: 12, [emptyImport, emptyCreate])
        emptyButtons.align(horizontal: GTK_ALIGN_CENTER)
        adw_status_page_set_child(empty.cast(), emptyButtons)

        gtk_stack_add_named(stack.cast(), UI.scrolled(shelf), "machines")
        gtk_stack_add_named(stack.cast(), empty, "empty")

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), stack)
        adw_window_set_content(window.cast(), toolbar)
        // A narrow window has the buttons under the heading.
        let narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 700sp"))!
        la_breakpoint_set_orientation(narrow, heading.raw, GTK_ORIENTATION_VERTICAL)
        adw_window_add_breakpoint(window.cast(), narrow)
    }

    // MARK: The machines

    fileprivate func showTiles() {
        let entries = machines.entries
        gtk_stack_set_visible_child_name(stack.cast(), entries.isEmpty ? "empty" : "machines")
        rebuilding = true
        defer { rebuilding = false }
        gtk_flow_box_remove_all(grid.cast())
        tileIDs = entries.map(\.id)
        for entry in entries {
            gtk_flow_box_append(grid.cast(), tile(entry))
        }
        if let selection, let index = tileIDs.firstIndex(of: selection),
           let child = gtk_flow_box_get_child_at_index(grid.cast(), Int32(index)) {
            gtk_flow_box_select_child(grid.cast(), child)
        } else if selection != nil {
            // It's gone (removed).
            after(0) { [weak self] in self?.selection = nil }
        }
        updateStart()
    }

    private func updateStart() {
        startButton.setSensitive(selection.flatMap(machines.entry).map { $0.problem == nil } ?? false)
    }

    /// A saved machine: its screen when saved, its name and what it is.
    private func tile(_ entry: MyMachines.Entry) -> Widget {
        let screen = gtk_overlay_new()!
        gtk_overlay_set_child(screen.cast(), MachineTiles.screen(entry))
        if machines.running(entry.id) != nil {
            let badge = UI.hbox(spacing: 4, [UI.image(icon: "media-playback-start-symbolic", size: 12), UI.label("Running")],
                                classes: ["running-badge"])
            badge.align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_START)
            badge.setMargins(8)
            gtk_widget_set_can_target(badge, 0)
            gtk_overlay_add_overlay(screen.cast(), badge)
        }
        var lines = [caption(entry.name, classes: ["tile-title"]), caption(MachineTiles.summary(entry), classes: ["dim-label"])]
        if let rom = MachineTiles.rom(entry) { lines.append(caption(rom, classes: ["dim-label", "caption"])) }
        if let problem = entry.problem {
            let icon = UI.image(icon: "dialog-warning-symbolic", size: 14)
            icon.align(vertical: GTK_ALIGN_START)
            lines.append(UI.hbox(spacing: 6, [icon, caption(problem, classes: ["caption"], wrap: true)], classes: ["warning"]))
        }
        // The captions no wider than the screen.
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(clamp.cast(), MachineTiles.width)
        adw_clamp_set_tightening_threshold(clamp.cast(), MachineTiles.width)
        adw_clamp_set_child(clamp.cast(), UI.vbox(spacing: 10, [screen, UI.vbox(spacing: 3, lines)]))
        let box = UI.vbox(spacing: 0, [clamp], classes: ["tile"])
        box.setTooltip(entry.problem ?? "Double-click to start \(entry.name)")

        // Right-click: start, rename, duplicate, export, show, trash.
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click.cast(), 3)
        onClick(click, "pressed") { [weak self] _, x, y in
            guard let self else { return }
            var buttons: [(String, Handler)] = []
            if entry.problem == nil { buttons.append(("Start", { [weak self] in self?.start(entry.id) })) }
            buttons += [
                ("Rename…", { [weak self] in self?.rename(entry) }),
                ("Duplicate", { [weak self] in
                    do { try self?.machines.duplicate(entry.id) } catch {
                        Alerts.show("Could not duplicate \(entry.name)", Alerts.describe(error), parent: self?.window)
                    }
                }),
                ("Export Machine Configuration…", { [weak self] in self?.machines.export(entry.id, parent: self?.window) }),
                ("Show in Files", { [weak self] in revealInFileManager(entry.folder, parent: self?.window) }),
                ("Move to Trash", { [weak self] in
                    guard let self else { return }
                    if self.selection == entry.id { self.selection = nil }
                    self.machines.remove(entry.id, parent: self.window)
                }),
            ]
            Self.popupMenu(buttons, on: box, x: x, y: y)
        }
        box.addController(click)
        return box
    }

    private func caption(_ text: String, classes: [String], wrap: Bool = false) -> Widget {
        let label = UI.label(text, classes: classes, wrap: wrap)
        if wrap { gtk_label_set_lines(label.cast(), 3) }
        gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
        return label
    }

    /// A column of buttons in a popover at a point, as a context menu.
    private static func popupMenu(_ buttons: [(String, Handler)], on widget: Widget, x: Double, y: Double) {
        let popover = gtk_popover_new()!
        let column = UI.vbox(spacing: 2)
        for (title, action) in buttons {
            let button = UI.button(title, classes: ["flat"]) {
                gtk_popover_popdown(popover.cast())
                action()
            }
            if let label = gtk_button_get_child(button.cast()) { gtk_label_set_xalign(label.cast(), 0) }
            UI.append(column, button)
        }
        gtk_popover_set_child(popover.cast(), column)
        gtk_widget_set_parent(popover, widget)
        var point = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover.cast(), &point)
        onSignal(popover, "closed") { after(0) { gtk_widget_unparent(popover) } }
        gtk_popover_popup(popover.cast())
    }

    // MARK: Actions

    private func start(_ id: UUID) {
        selection = id
        guard machines.entry(id)?.problem == nil else { return }
        machines.start(id, parent: window)
    }

    private func rename(_ entry: MyMachines.Entry) {
        let field = gtk_entry_new()!
        UI.setText(editable: field, entry.name)
        gtk_entry_set_activates_default(field.cast(), 1)
        Alerts.askWithChild("Rename Machine", nil, child: field, button: "Rename", parent: window) { [weak self] in
            self?.machines.rename(entry.id, to: UI.text(of: field))
        }
        gtk_widget_grab_focus(field)
    }

    private func chooseImport() {
        machines.chooseAndImport(parent: window) { [weak self] id in self?.selection = id; self?.showTiles() }
    }

    func showCreate() {
        if let createDialog {
            createDialog.present()
            return
        }
        let dialog = CreateMachineDialog(parent: window) { [weak self] id in
            self?.selection = id
            self?.showTiles()
        } onClose: { [weak self] in
            self?.createDialog = nil
        }
        createDialog = dialog
        dialog.present()
    }

    /// Creates an entry with the Create Machine dialog showing (for
    /// self-tests).
    func createForSelfTest(name: String, model: MachineModel, cpu: CPUType, ramKB: Int, monitor: MonitorType, hardDiscs: [String?]) {
        createDialog?.create(name: name, model: model, cpu: cpu, ramKB: ramKB, monitor: monitor, hardDiscs: hardDiscs)
    }

    /// Selects an entry by its name (for self-tests).
    func select(named name: String) {
        selection = machines.entries.first { $0.name == name }?.id
        showTiles()
    }
}

/// What a My Machines tile shows.
@MainActor
enum MachineTiles {
    static let width: Int32 = 240

    /// The screen when it was saved (4:3), or the model's picture. (A
    /// picture wants to be as big as its texture: the tile clamps it.)
    static func screen(_ entry: MyMachines.Entry) -> Widget {
        let height = width * 3 / 4
        if let texture = Covers.texture(entry.screenURL) {
            let picture = gtk_picture_new_for_paintable(texture)!
            gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
            gtk_picture_set_can_shrink(picture.cast(), 1)
            gtk_widget_set_size_request(picture, width, height)
            picture.addClass("machine-screen")
            gtk_widget_set_overflow(picture, GTK_OVERFLOW_HIDDEN)
            return picture
        }
        let icon = UI.image(icon: "computer-symbolic", size: 64)
        icon.addClass("dim-label")
        icon.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        icon.expand(horizontally: true, vertically: true)
        let placeholder = UI.vbox(spacing: 0, [icon], classes: ["machine-screen", "machine-placeholder"])
        gtk_widget_set_size_request(placeholder, width, height)
        return placeholder
    }

    /// Forgets a screen (it's been saved again).
    static func forget(_ url: URL) {
        Covers.forget(url)
    }

    /// "A3000 · ARM2 · 2 MB · 1 hard disc".
    static func summary(_ entry: MyMachines.Entry) -> String {
        guard let c = entry.configuration else { return "Can’t be read" }
        var parts = [c.model.rawValue, c.cpu.displayName, AppSettings.ramLabel(c.ramKB)]
        let discs = c.hardDiscs.compactMap { $0 }.count
        if discs > 0 { parts.append(discs == 1 ? "1 hard disc" : "\(discs) hard discs") }
        return parts.joined(separator: " · ")
    }

    /// The ROM, as the ROM menus name it (with its size, beside another the
    /// same version).
    static func rom(_ entry: MyMachines.Entry) -> String? {
        guard let path = entry.configuration?.romPaths.first else { return nil }
        if let e = AppSettings.shared.romLibrary.first(where: { $0.path == path }) { return AppSettings.shared.label(e) }
        return ROMLibrary.shared.detail(for: path)?.version
    }
}

/// Create Machine…: a new entry set up by hand, to start from the gallery.
/// (The Mac app's CreateMachineSheet.)
@MainActor
final class CreateMachineDialog {
    private let dialog: Widget
    private let parent: Widget
    private let created: @MainActor (UUID) -> Void
    private let onClose: Handler
    private let settings = AppSettings.shared
    private var nameEdited = false
    private var settingName = false
    private var model = AppSettings.shared.model
    private var cpu = AppSettings.shared.model.defaultCPU
    private var ramKB = AppSettings.shared.model.defaultRAMKB
    private var monitor = MonitorType.standard
    private var romPath = ""
    private var hardDiscs: [String?] = []
    /// The choices shown, as the rows list them.
    private var roms: [AppSettings.ROMEntry] = []
    /// Rows are being refilled: their selections aren't the user's.
    private var filling = false

    private let createButton: Widget
    private let nameRow: Widget
    private let modelRow: Widget
    private let processorRow: Widget
    private let memoryRow: Widget
    private let monitorRow: Widget
    private let romRow: Widget
    private let hardDiscGroup: Widget
    private var hardDiscRows: [Widget] = []
    private let note: Widget

    init(parent: Widget, created: @escaping @MainActor (UUID) -> Void, onClose: @escaping Handler) {
        self.parent = parent
        self.created = created
        self.onClose = onClose
        dialog = adw_dialog_new()!.widget
        createButton = gtk_button_new_with_label("Create")!
        nameRow = adw_entry_row_new()!
        let models = MachineModel.allCases
        modelRow = UI.comboRow("Model", models.map(\.displayName), selected: models.firstIndex(of: model) ?? 0) { _ in }
        processorRow = UI.comboRow("Processor", [], selected: 0) { _ in }
        memoryRow = UI.comboRow("Memory", [], selected: 0) { _ in }
        monitorRow = UI.comboRow("Monitor", [], selected: 0) { _ in }
        romRow = UI.comboRow("ROM", [], selected: 0) { _ in }
        hardDiscGroup = UI.preferencesGroup("Hard Discs")
        note = UI.label("", classes: ["dim-label"], wrap: true)
        build()
        modelChanged()
    }

    func present() {
        adw_dialog_present(dialog.cast(), parent)
    }

    func close() {
        adw_dialog_close(dialog.cast())
    }

    private func build() {
        adw_dialog_set_title(dialog.cast(), "Create Machine")
        adw_dialog_set_content_width(dialog.cast(), 560)
        adw_dialog_set_content_height(dialog.cast(), 640)

        let header = adw_header_bar_new()!
        adw_header_bar_set_show_start_title_buttons(header.cast(), 0)
        adw_header_bar_set_show_end_title_buttons(header.cast(), 0)
        adw_header_bar_pack_start(header.cast(), UI.button("Cancel") { [weak self] in self?.close() })
        createButton.addClass("suggested-action")
        onSignal(createButton, "clicked") { [weak self] in self?.create() }
        adw_header_bar_pack_end(header.cast(), createButton)
        adw_dialog_set_default_widget(dialog.cast(), createButton)

        adw_preferences_row_set_title(nameRow.cast(), "Name")
        adw_entry_row_set_activates_default(nameRow.cast(), 1)
        onNotify(nameRow, "text") { [weak self] in
            guard let self else { return }
            if !self.settingName { self.nameEdited = true }
            self.updateCreate()
        }
        let machine = UI.preferencesGroup(nil, [nameRow, modelRow, processorRow, memoryRow, monitorRow, romRow])

        let models = MachineModel.allCases
        onNotify(modelRow, "selected") { [weak self] in
            guard let self, !self.filling else { return }
            let index = Int(adw_combo_row_get_selected(self.modelRow.cast()))
            guard models.indices.contains(index), models[index] != self.model else { return }
            self.model = models[index]
            self.modelChanged()
        }
        onNotify(processorRow, "selected") { [weak self] in
            guard let self, !self.filling else { return }
            let choices = self.model.cpuChoices, index = Int(adw_combo_row_get_selected(self.processorRow.cast()))
            if choices.indices.contains(index) { self.cpu = choices[index] }
        }
        onNotify(memoryRow, "selected") { [weak self] in
            guard let self, !self.filling else { return }
            let choices = self.model.ramChoices, index = Int(adw_combo_row_get_selected(self.memoryRow.cast()))
            if choices.indices.contains(index) { self.ramKB = choices[index] }
        }
        onNotify(monitorRow, "selected") { [weak self] in
            guard let self, !self.filling else { return }
            let choices = self.model.monitorChoices, index = Int(adw_combo_row_get_selected(self.monitorRow.cast()))
            if choices.indices.contains(index) { self.monitor = choices[index] }
        }
        onNotify(romRow, "selected") { [weak self] in
            guard let self, !self.filling else { return }
            let index = Int(adw_combo_row_get_selected(self.romRow.cast()))
            if self.roms.indices.contains(index) { self.romPath = self.roms[index].path }
            self.suggestName()
            self.updateCreate()
        }

        note.setMargins(top: 4)
        let notes = UI.preferencesGroup(nil, [note])
        let page = adw_preferences_page_new()!
        for group in [machine, hardDiscGroup, notes] {
            adw_preferences_page_add(page.cast(), group.cast())
        }
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), page)
        adw_dialog_set_child(dialog.cast(), toolbar)
        onSignal(dialog, "closed") { [weak self] in self?.onClose() }
    }

    /// A model brings its usual processor, memory and monitor, a ROM that
    /// suits it, and no hard discs (their sector sizes differ).
    private func modelChanged() {
        cpu = model.defaultCPU
        ramKB = model.defaultRAMKB
        monitor = model.monitorChoices.contains(monitor) ? monitor : .standard
        roms = settings.romLibrary.filter { $0.suits(model) }
        if !roms.contains(where: { $0.path == romPath }) {
            romPath = settings.preferredROM(for: model, like: romPath.isEmpty ? settings.romPath : romPath) ?? ""
        }
        hardDiscs = Array(repeating: nil, count: model.hardDiscSlots)
        filling = true
        UI.setItems(comboRow: processorRow, model.cpuChoices.map(\.displayName), selected: model.cpuChoices.firstIndex(of: cpu) ?? 0)
        UI.setItems(comboRow: memoryRow, model.ramChoices.map(AppSettings.ramLabel), selected: model.ramChoices.firstIndex(of: ramKB) ?? 0)
        UI.setItems(comboRow: monitorRow, model.monitorChoices.map(\.displayName), selected: model.monitorChoices.firstIndex(of: monitor) ?? 0)
        UI.setItems(comboRow: romRow, roms.isEmpty ? ["No ROM suits the \(model.rawValue)"] : roms.map(settings.label),
                    selected: roms.firstIndex { $0.path == romPath } ?? 0)
        filling = false
        processorRow.setSensitive(model.cpuChoices.count > 1)
        monitorRow.setSensitive(model.monitorChoices.count > 1)
        romRow.setSensitive(!roms.isEmpty)
        UI.setText(note, model.hardDiscSlots == 0
                   ? "The first start sets RISC OS’s settings to their defaults; it keeps them after that."
                   : "Hard discs are used where they are, not copied. The first start sets RISC OS’s settings to their defaults; it keeps them after that.")
        showHardDiscs()
        suggestName()
        updateCreate()
    }

    private func suggestName() {
        guard !nameEdited else { return }
        let rom = settings.romLibrary.first { $0.path == romPath }.map { $0.version.components(separatedBy: " (").first ?? $0.version }
        settingName = true
        UI.setText(editable: nameRow, rom.map { "\(model.rawValue) with \($0)" } ?? model.rawValue)
        settingName = false
    }

    private var name: String { UI.text(of: nameRow).trimmingCharacters(in: .whitespaces) }

    private func updateCreate() {
        createButton.setSensitive(!romPath.isEmpty && !name.isEmpty)
    }

    /// Each drive, with New…, Choose… and Remove.
    private func showHardDiscs() {
        for row in hardDiscRows { adw_preferences_group_remove(hardDiscGroup.cast(), row) }
        hardDiscRows = []
        hardDiscGroup.setVisible(model.hardDiscSlots > 0)
        let kind = model.hasIDE ? "IDE" : "ST506"
        for drive in 0..<model.hardDiscSlots {
            let path = hardDiscs.indices.contains(drive) ? hardDiscs[drive] : nil
            let newButton = UI.button("New…", classes: ["flat"]) { [weak self] in self?.newHardDisc(drive) }
            newButton.setTooltip("Make a new, formatted hard disc image for this drive")
            let chooseButton = UI.button("Choose…", classes: ["flat"]) { [weak self] in self?.chooseHardDisc(drive) }
            chooseButton.setTooltip("Use a hard disc image you have")
            var suffixes = [newButton, chooseButton]
            if path != nil {
                suffixes.append(UI.iconButton("edit-clear-symbolic", tooltip: "Take the hard disc out (the image file keeps its contents)",
                                              classes: ["flat"]) { [weak self] in
                    self?.hardDiscs[drive] = nil
                    self?.showHardDiscs()
                })
            }
            let row = UI.actionRow("Hard disc \(drive + 4)", subtitle: path.map { ($0 as NSString).lastPathComponent } ?? "No \(kind) drive",
                                   suffixes: suffixes)
            adw_preferences_group_add(hardDiscGroup.cast(), row)
            hardDiscRows.append(row)
        }
    }

    /// A new, formatted hard disc of a chosen size.
    private func newHardDisc(_ drive: Int) {
        let base = name.isEmpty ? model.rawValue : name
        let file = String("\(base) drive \(drive + 4).hdf".map { "/:".contains($0) ? "-" : $0 })
        let model = model
        Task {
            guard let (url, geometry, system) = await MachineController.chooseNewHardDisc(model: model, drive: drive, heading: "New Hard Disc", message: {
                $0 ? "A new formatted hard disc, with !System, !Scrap and Library, for drive \(drive + 4) of \(base)."
                   : "A new hard disc, formatted and empty, for drive \(drive + 4) of \(base)."
            }, name: file, parent: parent) else { return }
            do {
                try ADFSFormatter.createFormattedImage(path: url.path, geometry: geometry, name: (url.lastPathComponent as NSString).deletingPathExtension,
                                                       system: system)
                guard model == self.model, hardDiscs.indices.contains(drive) else { return }
                hardDiscs[drive] = url.path
                showHardDiscs()
            } catch {
                Alerts.show("Could not create the hard disc", Alerts.describe(error), parent: dialog)
            }
        }
    }

    private func chooseHardDisc(_ drive: Int) {
        let model = model
        let kind = model.hasIDE ? "IDE hard disc image (.hdf, raw 512-byte sectors)" : "ST506 hard disc image (.hdf, raw 256-byte sectors)"
        FileDialogs.open(parent: parent, title: "Choose an \(kind) for Drive \(drive + 4)", filters: [MachineController.hardDiscFilter]) { [weak self] url in
            guard let self, model == self.model, self.hardDiscs.indices.contains(drive) else { return }
            do {
                _ = try HardDiscImage.open(path: url.path, sectorSize: model.hardDiscSectorSize)
                self.hardDiscs[drive] = url.path
                self.showHardDiscs()
            } catch {
                Alerts.show("Could not use \(url.lastPathComponent)", Alerts.describe(error), parent: self.dialog)
            }
        }
    }

    private func create() {
        guard !romPath.isEmpty, !name.isEmpty else { return }
        do {
            let id = try MyMachines.shared.create(name: name, model: model, cpu: cpu, ramKB: ramKB, monitor: monitor,
                                                  romPath: romPath, hardDiscs: hardDiscs)
            created(id)
            close()
        } catch {
            Alerts.show("Could not create the machine", Alerts.describe(error), parent: dialog)
        }
    }

    /// Fills in and creates (for self-tests).
    func create(name: String, model: MachineModel, cpu: CPUType, ramKB: Int, monitor: MonitorType, hardDiscs: [String?]) {
        if let index = MachineModel.allCases.firstIndex(of: model) { adw_combo_row_set_selected(modelRow.cast(), guint(index)) }
        self.cpu = cpu; self.ramKB = ramKB; self.monitor = monitor; self.hardDiscs = hardDiscs
        UI.setText(editable: nameRow, name)
        create()
    }
}
