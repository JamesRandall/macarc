import ArchimedesCore
import CGtk
import Foundation

/// Show Disc Contents: the files on the floppy and hard discs in a machine's
/// drives, which drag out to the file manager (typed with ",xxx" suffixes)
/// and in from it, and can be renamed, retyped, relocked and deleted, with
/// undo. (The Mac app's, after LinuxBeeb's.)
@MainActor
final class DiscContentsWindow {
    let machine: MachineController
    let model: DiscContentsModel
    let window: Widget
    private let actions: Actions
    var onClose: Handler?

    private let drives: Widget
    private let nameEntry: Widget
    private let bootPicker: Widget
    private let summary: Widget
    private let header: Widget
    private let stack: Widget
    private let status: Widget
    private let statusButtons: Widget
    private let list: Widget
    private let breadcrumbs: Widget
    private let note: Widget
    private let spinner: Widget
    private var columnButtons: [DiscContentsModel.SortKey: Widget] = [:]
    /// The rows shown, in order, by entry.
    private var shown: [ADFSVolume.Entry] = []
    private var rows: [Widget] = []
    private var settingSelection = false
    private var updatingHeader = false
    private var timer: GLibTimer?

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(machine: MachineController) {
        self.machine = machine
        model = DiscContentsModel(machine: machine)
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_default_size(window.cast(), 720, 520)
        model.parentWidget = window

        let group = g_simple_action_group_new()!
        actions = Actions(OpaquePointer(group))
        gtk_widget_insert_action_group(window, "dc", OpaquePointer(group))
        g_object_unref(group.raw)

        drives = adw_toggle_group_new()!
        drives.setTooltip("The floppy drive, and the hard discs fitted")

        nameEntry = UI.entry(placeholder: "No name", width: 12)
        gtk_entry_set_max_length(nameEntry.cast(), 10)
        nameEntry.setTooltip("The disc’s name, as the Filer shows it (*NameDisc)")
        bootPicker = UI.dropDown(["Off", "Load", "Run", "Exec"]) { _ in }
        bootPicker.setTooltip("What a Shift-start does with the root’s !Boot (*Opt 4)")
        summary = UI.label("", classes: ["dim-label", "numeric"])
        header = UI.hbox(spacing: 12, [nameEntry, UI.label("Boot", classes: ["dim-label"]), bootPicker, UI.spacer(), summary])
        header.setMargins(top: 8, bottom: 8, start: 12, end: 12)

        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(list.cast(), GTK_SELECTION_MULTIPLE)
        gtk_list_box_set_activate_on_single_click(list.cast(), 0)
        list.addClass("rich-list")

        status = adw_status_page_new()!
        statusButtons = UI.hbox(spacing: 12)
        statusButtons.align(horizontal: GTK_ALIGN_CENTER)
        adw_status_page_set_child(status.cast(), statusButtons)

        stack = gtk_stack_new()!
        breadcrumbs = UI.hbox(spacing: 4)
        note = UI.label("", classes: ["dim-label"])
        gtk_label_set_ellipsize(note.cast(), PANGO_ELLIPSIZE_END)
        spinner = adw_spinner_new()!
        spinner.setVisible(false)
        buildContent()
        addActions()
        observeModel()

        onSignalReturning(window, "close-request") { [weak self] in
            guard let self else { return false }
            self.commitName()
            self.timer?.invalidate()
            self.onClose?()
            return false
        }
        onNotify(window, "is-active") { [weak self] in
            if let self, gtk_window_is_active(self.window.cast()) != 0 { self.model.reload() }
        }
        // RISC OS's own writes show up as they happen.
        timer = GLibTimer(interval: 1.5) { [weak self] in
            guard let self else { return false }
            Task { await self.model.refreshIfChanged() }
            return true
        }
    }

    /// Shows the window, at `drive` if it's given (and fitted).
    func present(drive: DiscDrive? = nil) {
        if let drive, model.drives.contains(drive) { model.drive = drive }
        model.reload()
        gtk_window_present(window.cast())
    }

    func close() {
        gtk_window_close(window.cast())
    }

    // MARK: Building

    static let columns: [(DiscContentsModel.SortKey, String, Int32)] = [
        (.name, "Name", 200), (.type, "Type", 100), (.size, "Size", 80), (.date, "Modified", 170), (.access, "Access", 70),
    ]

    private func buildContent() {
        let headerBar = adw_header_bar_new()!
        adw_header_bar_set_title_widget(headerBar.cast(), drives)
        for (icon, tooltip, action) in [("edit-undo-symbolic", "Undo", "dc.undo"), ("edit-redo-symbolic", "Redo", "dc.redo")] {
            adw_header_bar_pack_start(headerBar.cast(), UI.actionButton(icon: icon, tooltip: tooltip, action: action))
        }
        for (icon, tooltip, action) in [
            ("user-trash-symbolic", "Delete the selected files and directories", "dc.delete"),
            ("document-properties-symbolic", "Rename, retype or lock the selected file", "dc.info"),
            ("document-send-symbolic", "Copy the selected files to a folder", "dc.export"),
            ("folder-new-symbolic", "Make a directory", "dc.new-directory"),
            ("list-add-symbolic", "Copy files onto the disc", "dc.add"),
        ] {
            adw_header_bar_pack_end(headerBar.cast(), UI.actionButton(icon: icon, tooltip: tooltip, action: action))
        }

        // The files: a header of columns (click to sort), then the rows.
        let columns = UI.hbox(spacing: 0, classes: ["column-header"])
        for (key, title, width) in Self.columns {
            let button = gtk_button_new_with_label(title)!
            button.addClass("flat")
            gtk_widget_set_size_request(button, width, -1)
            if key == .name { button.expand(horizontally: true) }
            gtk_widget_set_halign(gtk_button_get_child(button.cast())!, GTK_ALIGN_START)
            onSignal(button, "clicked") { [weak self] in
                guard let self else { return }
                if self.model.sortKey == key {
                    self.model.sortAscending.toggle()
                } else {
                    self.model.sortKey = key
                    self.model.sortAscending = true
                }
            }
            columnButtons[key] = button
            UI.append(columns, button)
        }
        // (As the rows' cells are placed.)
        columns.setMargins(start: 12, end: 6)
        let scrolled = UI.scrolled(list)
        scrolled.expand(vertically: true)
        let files = UI.vbox(spacing: 0, [columns, UI.separator(), scrolled])
        gtk_stack_add_named(stack.cast(), files, "files")
        gtk_stack_add_named(stack.cast(), status, "problem")
        stack.expand(vertically: true)

        let footer = UI.hbox(spacing: 6, [breadcrumbs, UI.spacer(), spinner, note])
        footer.setMargins(top: 6, bottom: 6, start: 12, end: 12)

        let content = UI.vbox(spacing: 0, [header, UI.separator(), stack, UI.separator(), footer])
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), headerBar)
        adw_toolbar_view_set_content(toolbar.cast(), content)
        adw_window_set_content(window.cast(), toolbar)

        // The name goes in when it's entered or left.
        onSignal(nameEntry, "activate") { [weak self] in self?.commitName() }
        let focus = gtk_event_controller_focus_new()!
        onSignal(focus, "leave") { [weak self] in self?.commitName() }
        nameEntry.addController(focus)
        onNotify(bootPicker, "selected") { [weak self] in
            guard let self, !self.updatingHeader else { return }
            self.model.setBootOption(Int(gtk_drop_down_get_selected(self.bootPicker.cast())))
        }
        onNotify(drives, "active-name") { [weak self] in
            guard let self, let name = String(gBorrowed: adw_toggle_group_get_active_name(self.drives.cast())),
                  let drive = self.model.drives.first(where: { "\($0.number)" == name }), self.model.drive != drive else { return }
            self.commitName()
            self.model.drive = drive
        }

        onSignal(list, "selected-rows-changed") { [weak self] in
            guard let self, !self.settingSelection else { return }
            var ids = Set<String>()
            for (row, entry) in zip(self.rows, self.shown) where gtk_list_box_row_is_selected(row.cast()) != 0 {
                ids.insert(entry.id)
            }
            if self.model.selection != ids { self.model.selection = ids }
        }
        let activated: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, row, data in
            let window = Unmanaged<DiscContentsWindow>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let row, let index = window.rows.firstIndex(where: { $0.raw == row }) else { return }
                window.openOrInfo(window.shown[index])
            }
        }
        la_signal_connect(list.raw, "row-activated", unsafeBitCast(activated, to: GCallback.self),
                          Unmanaged.passUnretained(self).toOpaque(), nil, 0)

        // Delete deletes; Ctrl+I shows a file's info; Alt+Up goes up a
        // directory and Alt+Down into the one selected.
        let keys = gtk_event_controller_key_new()!
        onKey(keys, "key-pressed") { [weak self] keyval, _, state in
            guard let self else { return false }
            let selected = self.model.selectedItems
            if keyval == UInt32(GDK_KEY_Delete) || keyval == UInt32(GDK_KEY_BackSpace) {
                self.model.delete(selected)
                return true
            }
            if keyval == UInt32(GDK_KEY_i) && state.rawValue & GDK_CONTROL_MASK.rawValue != 0 {
                self.showInfo()
                return true
            }
            if state.rawValue & GDK_ALT_MASK.rawValue != 0 {
                if keyval == UInt32(GDK_KEY_Up), !self.model.path.isEmpty {
                    self.model.goUp(to: self.model.path.count - 1)
                    return true
                }
                if keyval == UInt32(GDK_KEY_Down), selected.count == 1, selected[0].isDirectory {
                    self.model.open(selected[0])
                    return true
                }
            }
            return false
        }
        list.addController(keys)

        // A context menu, for the row clicked.
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click.cast(), 3)
        onClick(click, "pressed") { [weak self] _, x, y in self?.showMenu(x: x, y: y) }
        list.addController(click)

        // Files dropped in go on the disc (onto a directory's row: into it).
        acceptFileDrops(on: list) { [weak self] urls in
            guard let self, self.model.volume != nil else { return false }
            self.model.add(urls)
            return true
        }

        // Undo and redo in this window.
        let shortcuts = gtk_shortcut_controller_new()!
        for (trigger, action) in [("<Control>z", "dc.undo"), ("<Control><Shift>z", "dc.redo"), ("<Control>y", "dc.redo")] {
            gtk_shortcut_controller_add_shortcut(shortcuts.opaque,
                                                 gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger), gtk_named_action_new(action)))
        }
        window.addController(shortcuts)
    }

    private func commitName() {
        guard model.volume != nil, model.problem == nil else { return }
        let text = UI.text(of: nameEntry)
        if ADFSVolume.isValidDiscName(text) {
            model.setDiscName(text)
        } else {
            UI.setText(editable: nameEntry, model.discName)
        }
    }

    // MARK: Actions

    private func addActions() {
        let model = model
        actions.add("undo") { model.undo.undo() }
        actions.add("redo") { model.undo.redo() }
        actions.add("delete") { model.delete(model.selectedItems) }
        actions.add("info") { [weak self] in self?.showInfo() }
        actions.add("export") { [weak self] in self?.exportSelection() }
        actions.add("export-text") { [weak self] in
            guard let self, let entry = model.selectedItems.first else { return }
            model.exportAsText(entry, parent: self.window)
        }
        actions.add("open") { [weak self] in
            if let entry = model.selectedItems.first { self?.openOrInfo(entry) }
        }
        actions.add("new-directory") { [weak self] in self?.askForDirectoryName() }
        actions.add("add") { [weak self] in self?.addFiles() }
        actions.add("new-disc", string: { [weak self] format in
            guard let self, let format = ADFSFloppyFormatter.Format(rawValue: format) else { return }
            Task { @MainActor in await self.machine.insertBlankDisc(format) }
        })
        actions.add("insert-disc") { [weak self] in self?.machine.openDisc() }
    }

    private func openOrInfo(_ entry: ADFSVolume.Entry) {
        if entry.isDirectory { model.open(entry) } else { showInfo(entry) }
    }

    private func showInfo(_ entry: ADFSVolume.Entry? = nil) {
        guard let entry = entry ?? model.selectedItems.first, let volume = model.volume else { return }
        FileInfoDialog.present(parent: window, entry: entry, oldDirectories: volume.hasOldDirectories) { [weak self] name, load, exec, attributes in
            self?.model.update(entry, name: name, load: load, exec: exec, attributes: attributes)
        }
    }

    private func askForDirectoryName() {
        let entry = gtk_entry_new()!
        gtk_entry_set_max_length(entry.cast(), 10)
        gtk_entry_set_activates_default(entry.cast(), 1)
        Alerts.askWithChild("New Directory", nil, child: entry, button: "Make", parent: window) { [weak self] in
            let name = UI.text(of: entry)
            guard ADFSVolume.isValidName(name) else {
                Alerts.show("“\(name)” can’t be a directory’s name",
                            "Up to 10 characters, without spaces or $ & @ ^ % \\ : . # * \" |", parent: self?.window)
                return
            }
            self?.model.makeDirectory(name)
        }
    }

    /// (Folders come in by dragging: GTK's chooser picks files or folders,
    /// not both.)
    private func addFiles() {
        let title = "Add Files (a “,xxx” suffix on a name gives its RISC OS type; .bas text becomes a BASIC program)"
        FileDialogs.openMultiple(parent: window, title: title) { [weak self] urls in
            self?.model.add(urls)
        }
    }

    private func exportSelection() {
        let entries = model.selectedItems
        guard !entries.isEmpty else { return }
        FileDialogs.chooseFolder(parent: window, title: "Export To (files are named with their RISC OS types, “,fff” for Text and so on)") { [weak self] folder in
            do {
                try self?.model.export(entries, to: folder)
            } catch {
                Alerts.show(error, parent: self?.window)
            }
        }
    }

    private func showMenu(x: Double, y: Double) {
        // The row clicked joins the selection if it isn't in it.
        if let row = gtk_list_box_get_row_at_y(list.cast(), Int32(y)), gtk_list_box_row_is_selected(row) == 0 {
            gtk_list_box_unselect_all(list.cast())
            gtk_list_box_select_row(list.cast(), row)
        }
        let entries = model.selectedItems
        guard !entries.isEmpty else { return }
        let menu = Menu()
        if entries.count == 1 {
            if entries[0].isDirectory { menu.item("Open", "dc.open") }
            menu.item("Get Info", "dc.info")
        }
        menu.item("Export…", "dc.export")
        if entries.count == 1, model.isBASIC(entries[0]) {
            menu.item("Export as Text…", "dc.export-text")
        }
        menu.section { $0.item("Delete", "dc.delete") }
        let popover = gtk_popover_menu_new_from_model(menu.model)!
        gtk_widget_set_parent(popover, list)
        var point = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover.cast(), &point)
        gtk_popover_set_has_arrow(popover.cast(), 0)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
        onSignal(popover, "closed") {
            after(0) { gtk_widget_unparent(popover) }
        }
        gtk_popover_popup(popover.cast())
    }

    // MARK: Showing

    private func observeModel() {
        let model = model
        let machine = machine
        observe(self) { [weak self] in
            guard let self else { return }
            let volume = model.volume
            let drives = model.drives
            // The drives.
            let names = drives.map { "\($0.number)" }
            var current: [String] = []
            for index in 0..<adw_toggle_group_get_n_toggles(self.drives.cast()) {
                if let toggle = adw_toggle_group_get_toggle(self.drives.cast(), index), let name = String(gBorrowed: adw_toggle_get_name(toggle)) {
                    current.append(name)
                }
            }
            if current != names {
                adw_toggle_group_remove_all(self.drives.cast())
                for drive in drives {
                    let toggle = adw_toggle_new()!
                    adw_toggle_set_name(toggle, "\(drive.number)")
                    adw_toggle_set_label(toggle, drive.name)
                    adw_toggle_group_add(self.drives.cast(), toggle)
                }
            }
            if String(gBorrowed: adw_toggle_group_get_active_name(self.drives.cast())) != "\(model.drive.number)" {
                adw_toggle_group_set_active_name(self.drives.cast(), "\(model.drive.number)")
            }
            let disc: String? = switch model.drive {
            case .floppy: machine.discName
            case .hard(let slot): machine.hardDiscName(slot)
            }
            gtk_window_set_title(self.window.cast(), model.drive.name + (disc.map { " — \($0)" } ?? ""))

            // The header: the name, boot option and space.
            let problem = model.problem
            self.header.setVisible(problem == nil && volume != nil)
            if gtk_widget_has_focus(gtk_widget_get_first_child(self.nameEntry)) == 0 {
                UI.setText(editable: self.nameEntry, model.discName)
            }
            self.updatingHeader = true
            UI.select(self.bootPicker, model.bootOption)
            self.updatingHeader = false
            UI.setText(self.summary, model.summary)

            // The files, or why there aren't any.
            if let problem {
                adw_status_page_set_title(self.status.cast(), problem)
                adw_status_page_set_icon_name(self.status.cast(), model.drive == .floppy ? "media-floppy-symbolic" : "drive-harddisk-symbolic")
                UI.removeAll(self.statusButtons)
                if model.isEmptyFloppy {
                    let formats = Menu()
                    for format in ADFSFloppyFormatter.Format.allCases {
                        formats.item(format.name, "dc.new-disc", string: format.rawValue)
                    }
                    let newDisc = gtk_menu_button_new()!
                    gtk_menu_button_set_label(newDisc.cast(), "New Disc")
                    gtk_menu_button_set_menu_model(newDisc.cast(), formats.model)
                    newDisc.addClass("pill")
                    UI.append(self.statusButtons, newDisc)
                    let insert = UI.button("Insert Disc…", classes: ["suggested-action", "pill"]) {}
                    gtk_actionable_set_action_name(insert.cast(), "dc.insert-disc")
                    UI.append(self.statusButtons, insert)
                }
                gtk_stack_set_visible_child_name(self.stack.cast(), "problem")
            } else if volume == nil {
                adw_status_page_set_title(self.status.cast(), "")
                UI.removeAll(self.statusButtons)
                gtk_stack_set_visible_child_name(self.stack.cast(), "problem")
            } else {
                gtk_stack_set_visible_child_name(self.stack.cast(), "files")
            }
            self.showItems(model.items)
            self.showSelection(model.selection)
            for (key, title, _) in Self.columns {
                let arrow = model.sortKey == key ? (model.sortAscending ? " ▲" : " ▼") : ""
                gtk_button_set_label(self.columnButtons[key]?.cast(), title + arrow)
            }

            // The footer: where in the disc, and what's happening.
            UI.removeAll(self.breadcrumbs)
            if problem == nil, volume != nil {
                UI.append(self.breadcrumbs, self.crumb(":\(model.drive.number).$", depth: 0))
                for (depth, name) in model.path.enumerated() {
                    UI.append(self.breadcrumbs, UI.label("›", classes: ["dim-label"]))
                    UI.append(self.breadcrumbs, self.crumb(name, depth: depth + 1))
                }
            }
            self.spinner.setVisible(model.waiting)
            let text: String
            if model.waiting {
                text = model.drive == .floppy ? "Waiting for the floppy drive to stop…" : "Waiting for the hard disc to be still…"
            } else if model.drive == .floppy && machine.disc.modified && volume != nil {
                text = machine.disc.savable ? "Changes are in memory until Disc ▸ Save Disc Changes." : "Changes to this image can’t be saved back to it."
            } else if model.drive != .floppy && volume != nil {
                text = "Changing a hard disc restarts the machine."
            } else {
                text = ""
            }
            UI.setText(self.note, text)

            // Actions that need a selection, or a disc.
            let editable = volume != nil && problem == nil
            self.actions["add"]?.isEnabled = editable
            self.actions["new-directory"]?.isEnabled = editable
            self.actions["export"]?.isEnabled = !model.selection.isEmpty
            self.actions["delete"]?.isEnabled = !model.selection.isEmpty
            self.actions["info"]?.isEnabled = model.selection.count == 1
            self.actions["undo"]?.isEnabled = model.undo.undoName != nil
            self.actions["redo"]?.isEnabled = model.undo.redoName != nil
        }
        // A disc in or out, a hard disc fitted, or a new machine: read again.
        observe(self) { [weak self] in
            _ = (machine.discName, machine.hardDiscs, machine.host.map(ObjectIdentifier.init))
            self?.model.reload()
        }
        observe(self) { [weak self] in
            guard let self, let alert = self.model.alert else { return }
            let title = self.model.alertTitle
            after(0) { [weak self] in
                guard let self else { return }
                self.model.alert = nil
                self.model.alertTitle = DiscContentsModel.cantChange
                Alerts.show(title, alert, parent: self.window)
            }
        }
    }

    private func crumb(_ title: String, depth: Int) -> Widget {
        UI.button(title, classes: ["flat"]) { [weak self] in self?.model.goUp(to: depth) }
    }

    private static func icon(_ e: ADFSVolume.Entry) -> String {
        if e.isApplication { return "application-x-executable-symbolic" }
        if e.isDirectory { return "folder-symbolic" }
        switch e.fileType {
        case 0xFFF?, 0xFEB?: return "text-x-generic-symbolic"
        case 0xFFB?, 0xFD1?: return "text-x-script-symbolic"
        case 0xFF9?, 0x695?, 0xC85?, 0xB60?, 0xFF0?, 0x69C?, 0xAFF?: return "image-x-generic-symbolic"
        case 0xFF8?, 0xFFA?, 0xFFC?, 0xFE6?: return "application-x-executable-symbolic"
        case 0xFAF?: return "text-html-symbolic"
        case 0xA91?, 0xDDC?, 0xD94?, 0xF89?: return "package-x-generic-symbolic"
        default: return "application-x-generic-symbolic"
        }
    }

    private func showItems(_ entries: [ADFSVolume.Entry]) {
        guard entries != shown else { return }
        gtk_list_box_remove_all(list.cast())
        rows = []
        shown = entries
        for entry in entries {
            let icon = UI.image(icon: Self.icon(entry))
            let name = UI.label(entry.name)
            name.expand(horizontally: true)
            gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_END)
            // (Narrow natural widths, so the columns are the widths asked for.)
            gtk_label_set_max_width_chars(name.cast(), 1)
            let nameBox = UI.hbox(spacing: 6, [icon, name])
            gtk_widget_set_size_request(nameBox, Self.columns[0].2, -1)
            nameBox.expand(horizontally: true)
            nameBox.setMargins(start: 6)
            var cells = [nameBox]
            let size = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(entry.length), countStyle: .file)
            for (index, (text, classes)) in [(DiscContentsModel.typeName(entry), [String]()), (size, []),
                                             (entry.date.map(Self.dates.string) ?? "", []), (entry.access, ["code-small"])].enumerated() {
                let label = UI.label(text, classes: classes)
                gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
                gtk_label_set_max_width_chars(label.cast(), 1)
                label.setTooltip(text)
                // (A rich list's labels are padded 6 px either side, as the
                // headings' buttons are.)
                gtk_widget_set_size_request(label, Self.columns[index + 1].2 - 12, -1)
                cells.append(label)
            }
            let content = UI.hbox(spacing: 0, cells)
            content.setMargins(top: 4, bottom: 4)
            let row = gtk_list_box_row_new()!
            gtk_list_box_row_set_child(row.cast(), content)
            addDragSource(to: row, entry: entry)
            if entry.isDirectory {
                // Dropped on a directory: into it.
                acceptFileDrops(on: row) { [weak self] urls in
                    guard let self, self.model.volume != nil else { return false }
                    self.model.add(urls, into: entry.name)
                    return true
                }
            }
            rows.append(row)
            gtk_list_box_append(list.cast(), row)
        }
    }

    private func showSelection(_ selection: Set<String>) {
        settingSelection = true
        defer { settingSelection = false }
        for (row, entry) in zip(rows, shown) {
            let selected = gtk_list_box_row_is_selected(row.cast()) != 0
            if selected != selection.contains(entry.id) {
                if selected { gtk_list_box_unselect_row(list.cast(), row.cast()) } else { gtk_list_box_select_row(list.cast(), row.cast()) }
            }
        }
    }

    // MARK: Dragging out

    /// Dragging a row out drags the selected files (or that one), written to
    /// a temporary folder with their types in their names, for the file
    /// manager to copy.
    private func addDragSource(to row: Widget, entry: ADFSVolume.Entry) {
        let source = gtk_drag_source_new()!
        gtk_drag_source_set_actions(source, GDK_ACTION_COPY)
        let prepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { _, _, _, data in
            let (window, entry) = Box<(DiscContentsWindow, ADFSVolume.Entry)>.from(data)
            // (A pointer isn't Sendable, so it comes out of the closure this way.)
            var content: OpaquePointer?
            MainActor.assumeIsolated { content = window.dragContent(entry) }
            return content
        }
        la_signal_connect(source.raw, "prepare", unsafeBitCast(prepare, to: GCallback.self),
                          Box((self, entry)).retained, releaseBox, 0)
        row.addController(source)
    }

    private func dragContent(_ entry: ADFSVolume.Entry) -> OpaquePointer? {
        guard model.volume != nil else { return nil }
        let entries = model.selection.contains(entry.id) ? model.selectedItems : [entry]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linuxarch-drag-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try model.export(entries, to: folder)
            var paths = entries.map { strdup(folder.appendingPathComponent(ADFSExport.macName($0)).path) } + [nil]
            defer { paths.forEach { free($0) } }
            return paths.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { la_content_provider_for_paths($0.baseAddress).opaque }
            }
        } catch {
            Alerts.show(error, parent: window)
            return nil
        }
    }
}

/// A file's (or directory's) name, type or addresses, date and access.
@MainActor
enum FileInfoDialog {
    static func present(parent: Widget?, entry: ADFSVolume.Entry, oldDirectories: Bool,
                        onSave: @escaping @MainActor (String, UInt32, UInt32, UInt8) -> Void) {
        let name = adw_entry_row_new()!
        adw_preferences_row_set_title(name.cast(), "Name")
        UI.setText(editable: name, entry.name)
        let kinds = ["Typed and dated", "Load and execution addresses"]
        var typed = entry.isTyped
        let kind = UI.comboRow("Kind", kinds, selected: typed ? 0 : 1) { _ in }
        let type = adw_entry_row_new()!
        adw_preferences_row_set_title(type.cast(), "Type (Text, BASIC, Obey, &FFD…)")
        UI.setText(editable: type, entry.fileType.map(RISCOSFileType.name) ?? "Data")
        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = adw_entry_row_new()!
        adw_preferences_row_set_title(date.cast(), "Modified (year-month-day hours:minutes:seconds)")
        UI.setText(editable: date, dateFormat.string(from: entry.date ?? Date()))
        let load = adw_entry_row_new()!
        adw_preferences_row_set_title(load.cast(), "Load address")
        UI.setText(editable: load, String(format: "%08X", entry.load))
        let exec = adw_entry_row_new()!
        adw_preferences_row_set_title(exec.cast(), "Execution address")
        UI.setText(editable: exec, String(format: "%08X", entry.exec))
        let size = UI.actionRow("Size", suffixes: [UI.label("\(entry.length) bytes (&\(String(entry.length, radix: 16, uppercase: true)))",
                                                            classes: ["dim-label"])])

        let a = entry.attributes
        func switchRow(_ title: String, _ on: Bool) -> Widget {
            let row = adw_switch_row_new()!
            adw_preferences_row_set_title(row.cast(), title)
            adw_switch_row_set_active(row.cast(), on ? 1 : 0)
            return row
        }
        let locked = switchRow("Locked", a & 0x04 != 0)
        let ownerRead = switchRow("Read (you)", a & 0x01 != 0)
        let ownerWrite = switchRow("Write (you)", a & 0x02 != 0)
        let publicRead = switchRow("Read (others, on a network)", a & 0x10 != 0)
        let publicWrite = switchRow("Write (others, on a network)", a & 0x20 != 0)

        let details = adw_preferences_group_new()!
        var rows = [name]
        if !entry.isDirectory { rows += [kind, type, date, load, exec, size] }
        for row in rows { adw_preferences_group_add(details.cast(), row) }
        let access = UI.preferencesGroup("Access", [locked, ownerRead, ownerWrite] + (oldDirectories ? [] : [publicRead, publicWrite]))
        let problem = UI.label("", classes: ["error-text", "caption"], wrap: true)
        problem.setMargins(top: 8)
        adw_preferences_group_add(access.cast(), problem)

        func showKind() {
            type.setVisible(typed); date.setVisible(typed)
            load.setVisible(!typed); exec.setVisible(!typed)
        }
        showKind()

        let dialog = adw_dialog_new()!
        adw_dialog_set_title(dialog.cast(), "Info for “\(entry.name)”")
        adw_dialog_set_content_width(dialog.cast(), 460)
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_end_title_buttons(header.cast(), 0)
        adw_header_bar_set_show_start_title_buttons(header.cast(), 0)
        let cancel = UI.button("Cancel") { adw_dialog_close(dialog.cast()) }
        let save = UI.button("Save", classes: ["suggested-action"]) {}
        adw_header_bar_pack_start(header.cast(), cancel)
        adw_header_bar_pack_end(header.cast(), save)
        let page = adw_preferences_page_new()!
        adw_preferences_page_add(page.cast(), details.cast())
        adw_preferences_page_add(page.cast(), access.cast())
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), page)
        adw_dialog_set_child(dialog.cast(), toolbar)
        adw_dialog_set_default_widget(dialog.cast(), save)

        func on(_ row: Widget) -> Bool { adw_switch_row_get_active(row.cast()) != 0 }
        var attributes: UInt8 {
            (on(ownerRead) ? 0x01 : 0) | (on(ownerWrite) ? 0x02 : 0) | (on(locked) ? 0x04 : 0)
                | (!oldDirectories && on(publicRead) ? 0x10 : 0) | (!oldDirectories && on(publicWrite) ? 0x20 : 0)
        }
        func addresses() -> (UInt32, UInt32)? {
            if entry.isDirectory { return (entry.load, entry.exec) }
            if typed {
                guard let t = RISCOSFileType.type(named: UI.text(of: type)),
                      let when = dateFormat.date(from: UI.text(of: date).trimmingCharacters(in: .whitespaces)) else { return nil }
                return ADFSVolume.stamp(type: t, date: when)
            }
            guard let l = hex(UI.text(of: load)), let e = hex(UI.text(of: exec)) else { return nil }
            return (l, e)
        }
        func validate() -> Bool {
            let text = UI.text(of: name)
            var message: String?
            if !ADFSVolume.isValidName(text) {
                message = "Up to 10 characters, without spaces or $ & @ ^ % \\ : . # * \" |"
            } else if oldDirectories && !text.unicodeScalars.allSatisfy({ $0.isASCII }) {
                message = "Names on this disc are plain ASCII: no accented letters or hard spaces."
            } else if addresses() == nil {
                message = typed ? "A type is a name such as Text or BASIC, or three hex digits (&FFF); a date is as 2026-10-29 12:00:00."
                    : "Addresses are up to 8 hex digits."
            }
            UI.setText(problem, message ?? "")
            save.setSensitive(message == nil)
            return message == nil
        }
        onNotify(kind, "selected") {
            typed = adw_combo_row_get_selected(kind.cast()) == 0
            showKind()
            _ = validate()
        }
        for row in [name, type, date, load, exec] {
            onSignal(row, "changed") { _ = validate() }
        }
        onSignal(save, "clicked") {
            guard validate(), let (l, e) = addresses() else { return }
            onSave(UI.text(of: name), l, e, attributes)
            adw_dialog_close(dialog.cast())
        }
        _ = validate()
        adw_dialog_present(dialog.cast(), parent)
    }

    static func hex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces).uppercased()
        if digits.hasPrefix("&") { digits.removeFirst() } else if digits.hasPrefix("0X") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count <= 8 else { return nil }
        return UInt32(digits, radix: 16)
    }
}
