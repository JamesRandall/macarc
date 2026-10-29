import ArchimedesCore
import CGtk
import Foundation

/// The details of one of My Games being added or edited: what it's called,
/// its disc and cover, the machine it plays on, and how it starts. (The Mac
/// app's GameDetailsSheet, after LinuxBeeb's dialog.)
@MainActor
final class GameDetailsDialog {
    private static var open: [GameDetailsDialog] = []

    /// Shows a draft's details; `onClose` is called when they're saved or
    /// abandoned.
    static func present(draft: GameDraft, parent: Widget, onClose: @escaping Handler) {
        let dialog = GameDetailsDialog(draft: draft, parent: parent, onClose: onClose)
        open.append(dialog)
        adw_dialog_present(dialog.dialog.cast(), parent)
    }

    /// Saves the dialog in front (for self-tests).
    static func saveFront() {
        open.last?.save()
    }

    enum StartChoice: Int, CaseIterable {
        case application, boot, type, insertOnly

        var title: String {
            switch self {
            case .application: "Starting an application on the disc"
            case .boot: "Running the disc’s !Boot"
            case .type: "Typing a command at the command line"
            case .insertOnly: "Just putting the disc in"
            }
        }
    }

    /// RISC OS versions a game can ask for: the families, matched against
    /// the ROMs the user has.
    static let romChoices = ["RISC OS 2", "RISC OS 3"]

    private var draft: GameDraft
    private let library = GameLibrary.shared
    private let parent: Widget
    private let onClose: Handler
    private let dialog: Widget
    private var saving = false {
        didSet { updateSaveButton() }
    }
    private var saved = false
    private var startChoice = StartChoice.insertOnly
    /// The disc's applications, to choose one to start.
    private var applications: [String] = []

    private let saveButton: Widget
    private let coverWell: Widget
    private let titleRow: Widget
    private let publisherRow: Widget
    private let yearRow: Widget
    private let discRow: Widget
    private let discButton: Widget
    private let modelRow: Widget
    private let memoryRow: Widget
    private let romRow: Widget
    private var startChecks: [Widget] = []
    private let applicationRow: Widget
    private let applicationEntryRow: Widget
    private let commandRow: Widget
    private let notes: Widget
    private let laterNote: Widget

    private init(draft: GameDraft, parent: Widget, onClose: @escaping Handler) {
        self.draft = draft
        self.parent = parent
        self.onClose = onClose
        dialog = adw_dialog_new()!.widget
        saveButton = gtk_button_new_with_label(draft.isNew ? "Add Game" : "Save")!
        coverWell = gtk_button_new()!
        titleRow = adw_entry_row_new()!
        publisherRow = adw_entry_row_new()!
        yearRow = adw_entry_row_new()!
        discRow = adw_action_row_new()!
        discButton = gtk_button_new()!
        modelRow = adw_combo_row_new()!
        memoryRow = adw_combo_row_new()!
        romRow = adw_combo_row_new()!
        applicationRow = adw_combo_row_new()!
        applicationEntryRow = adw_entry_row_new()!
        commandRow = adw_entry_row_new()!
        notes = gtk_text_view_new()!
        laterNote = UI.label("You can add the disc later: drop it on the game.", classes: ["dim-label"], wrap: true)
        applications = draft.disc?.applications ?? existingApplications
        switch draft.game.start {
        case .boot: startChoice = .boot
        case .application(let name):
            startChoice = .application
            UI.setText(editable: applicationEntryRow, name)
        case .insertOnly: startChoice = .insertOnly
        case .type(let command):
            startChoice = .type
            UI.setText(editable: commandRow, command)
        }
        build()
    }

    /// The applications on the game's disc already (when editing).
    private var existingApplications: [String] {
        guard !draft.isNew, let url = library.myGames.discURL(draft.game),
              let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return MyGames.applications(onDisc: [UInt8](data))
    }

    // MARK: Building

    private func build() {
        adw_dialog_set_title(dialog.cast(), draft.isNew ? "Add a Game" : "Edit \(draft.game.title)")
        adw_dialog_set_content_width(dialog.cast(), 540)
        adw_dialog_set_content_height(dialog.cast(), 720)

        let header = adw_header_bar_new()!
        adw_header_bar_set_show_start_title_buttons(header.cast(), 0)
        adw_header_bar_set_show_end_title_buttons(header.cast(), 0)
        let cancel = UI.button("Cancel") { [weak self] in self?.close() }
        adw_header_bar_pack_start(header.cast(), cancel)
        saveButton.addClass("suggested-action")
        onSignal(saveButton, "clicked") { [weak self] in self?.save() }
        adw_header_bar_pack_end(header.cast(), saveButton)
        adw_dialog_set_default_widget(dialog.cast(), saveButton)

        let page = adw_preferences_page_new()!

        // The cover, and what it's called.
        gtk_widget_set_size_request(coverWell, 110, 150)
        coverWell.addClass("cover-well")
        coverWell.align(vertical: GTK_ALIGN_START)
        coverWell.setTooltip("Drop a picture here, or click to choose one")
        onSignal(coverWell, "clicked") { [weak self] in self?.chooseCover() }
        let names = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(names.cast(), GTK_SELECTION_NONE)
        names.addClass("boxed-list")
        names.expand(horizontally: true)
        names.align(vertical: GTK_ALIGN_START)
        for (row, title, text) in [(titleRow, "Title", draft.game.title), (publisherRow, "Publisher", draft.game.publisher ?? ""),
                                   (yearRow, "Year", draft.game.year.map(String.init) ?? "")] {
            adw_preferences_row_set_title(row.cast(), title)
            UI.setText(editable: row, text)
            gtk_list_box_append(names.cast(), row)
        }
        onNotify(titleRow, "text") { [weak self] in self?.updateSaveButton() }
        onSignal(titleRow, "entry-activated") { [weak self] in self?.save() }
        adw_entry_row_set_activates_default(publisherRow.cast(), 1)
        adw_entry_row_set_activates_default(yearRow.cast(), 1)
        la_set_int(yearRow.raw, "input-purpose", Int32(GTK_INPUT_PURPOSE_DIGITS.rawValue))
        let top = group(nil)
        adw_preferences_group_add(top.cast(), UI.hbox(spacing: 16, [coverWell, names]))
        adw_preferences_page_add(page.cast(), top.cast())

        // The disc.
        let disc = group("Disc")
        adw_action_row_add_prefix(discRow.cast(), UI.image(icon: "media-floppy-symbolic"))
        discButton.align(vertical: GTK_ALIGN_CENTER)
        onSignal(discButton, "clicked") { [weak self] in self?.chooseDisc() }
        adw_action_row_add_suffix(discRow.cast(), discButton)
        adw_preferences_group_add(disc.cast(), discRow)
        adw_preferences_page_add(page.cast(), disc.cast())

        // The machine to play it on.
        let machine = group("Machine")
        adw_preferences_row_set_title(modelRow.cast(), "Model")
        adw_combo_row_set_model(modelRow.cast(), UI.stringList(MachineModel.allCases.map(\.displayName)))
        adw_preferences_row_set_title(memoryRow.cast(), "Memory")
        adw_preferences_row_set_title(romRow.cast(), "RISC OS")
        let roms = ["As chosen in Preferences"] + Self.romChoices.map { family in
            AppSettings.shared.romLibrary.contains { $0.version.hasPrefix(family) } ? family : "\(family) (not in your ROMs)"
        }
        adw_combo_row_set_model(romRow.cast(), UI.stringList(roms))
        adw_combo_row_set_selected(romRow.cast(), guint(draft.game.rom.flatMap { Self.romChoices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0))
        onNotify(modelRow, "selected") { [weak self] in
            guard let self else { return }
            let index = Int(adw_combo_row_get_selected(self.modelRow.cast()))
            guard MachineModel.allCases.indices.contains(index) else { return }
            let model = MachineModel.allCases[index]
            guard model != self.draft.game.model else { return }
            self.draft.game.model = model
            if let kb = self.draft.game.ramKB, !model.ramChoices.contains(kb) { self.draft.game.ramKB = nil }
            self.showMachine()
        }
        onNotify(memoryRow, "selected") { [weak self] in
            guard let self else { return }
            let index = Int(adw_combo_row_get_selected(self.memoryRow.cast()))
            let choices = self.draft.game.model.ramChoices
            guard index != Int(GTK_INVALID_LIST_POSITION) else { return }
            self.draft.game.ramKB = index > 0 && index <= choices.count ? choices[index - 1] : nil
        }
        onNotify(romRow, "selected") { [weak self] in
            guard let self else { return }
            let index = Int(adw_combo_row_get_selected(self.romRow.cast()))
            guard index != Int(GTK_INVALID_LIST_POSITION) else { return }
            self.draft.game.rom = index > 0 && index <= Self.romChoices.count ? Self.romChoices[index - 1] : nil
        }
        for row in [modelRow, memoryRow, romRow] { adw_preferences_group_add(machine.cast(), row) }
        adw_preferences_page_add(page.cast(), machine.cast())

        // How to start it.
        let starting = group("Starting")
        var first: Widget?
        for choice in StartChoice.allCases {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(row.cast(), choice.title)
            let check = gtk_check_button_new()!
            if let first { gtk_check_button_set_group(check.cast(), first.cast()) } else { first = check }
            gtk_check_button_set_active(check.cast(), choice == startChoice ? 1 : 0)
            check.align(vertical: GTK_ALIGN_CENTER)
            adw_action_row_add_prefix(row.cast(), check)
            adw_action_row_set_activatable_widget(row.cast(), check)
            onSignal(check, "toggled") { [weak self] in
                guard let self, gtk_check_button_get_active(check.cast()) != 0 else { return }
                self.startChoice = choice
                self.showStart()
                if choice == .type { gtk_widget_grab_focus(self.commandRow) }
            }
            startChecks.append(check)
            adw_preferences_group_add(starting.cast(), row)
        }
        adw_preferences_row_set_title(applicationRow.cast(), "Application")
        adw_preferences_row_set_title(applicationEntryRow.cast(), "Application, such as !Game")
        applicationEntryRow.addClass("monospace")
        adw_preferences_row_set_title(commandRow.cast(), "Command, such as Run ADFS::0.$.!Game")
        commandRow.addClass("monospace")
        adw_entry_row_set_activates_default(commandRow.cast(), 1)
        let commandNote = UI.label("Typed after F12, at the desktop’s command line. Separate several with ;", classes: ["caption", "dim-label"], wrap: true)
        commandNote.setMargins(top: 4)
        for row in [applicationRow, applicationEntryRow, commandRow] { adw_preferences_group_add(starting.cast(), row) }
        adw_preferences_group_add(starting.cast(), commandNote)
        onNotify(commandRow, "visible") { [weak self] in
            guard let self else { return }
            commandNote.setVisible(gtk_widget_get_visible(self.commandRow) != 0)
        }
        adw_preferences_page_add(page.cast(), starting.cast())

        // Anything else worth knowing.
        let notesGroup = group("Notes", description: "Controls, tips, where it came from…")
        gtk_text_view_set_wrap_mode(notes.cast(), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(notes.cast(), 8)
        gtk_text_view_set_bottom_margin(notes.cast(), 8)
        gtk_text_view_set_left_margin(notes.cast(), 10)
        gtk_text_view_set_right_margin(notes.cast(), 10)
        gtk_text_view_set_accepts_tab(notes.cast(), 0)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(notes.cast()), draft.game.notes ?? "", -1)
        let frame = gtk_frame_new(nil)!
        gtk_frame_set_child(frame.cast(), notes)
        gtk_widget_set_size_request(frame, -1, 90)
        frame.addClass("view")
        adw_preferences_group_add(notesGroup.cast(), frame)
        laterNote.setMargins(top: 4)
        adw_preferences_group_add(notesGroup.cast(), laterNote)
        adw_preferences_page_add(page.cast(), notesGroup.cast())

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), page)
        adw_dialog_set_child(dialog.cast(), toolbar)

        acceptFileDrops(on: dialog) { [weak self] urls in self?.take(urls) ?? false }
        onSignal(dialog, "closed") { [weak self] in
            guard let self else { return }
            if !self.saved { self.library.cancel(self.draft) }
            Self.open.removeAll { $0 === self }
            self.onClose()
        }

        showCover()
        showDisc()
        showMachine()
        showStart()
        updateSaveButton()
        after(0) { [weak self] in
            guard let self else { return }
            gtk_widget_grab_focus(self.titleRow)
        }
    }

    private func group(_ title: String?, description: String? = nil) -> Widget {
        let group = adw_preferences_group_new()!
        if let title { adw_preferences_group_set_title(group.cast(), UI.escape(title)) }
        if let description { adw_preferences_group_set_description(group.cast(), UI.escape(description)) }
        return group
    }

    // MARK: Showing

    private func showCover() {
        let child: Widget
        if let url = draft.shownCover, let picture = Covers.picture(url, width: 102, height: 142, classes: []) {
            picture.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
            child = picture
        } else {
            let box = UI.vbox(spacing: 4, [UI.image(icon: "image-x-generic-symbolic", size: 28),
                                           UI.label("Drop a cover", classes: ["caption"], xalign: 0.5)])
            box.addClass("dim-label")
            box.align(vertical: GTK_ALIGN_CENTER)
            child = box
        }
        gtk_button_set_child(coverWell.cast(), child)
    }

    private func showDisc() {
        if let disc = draft.disc {
            adw_preferences_row_set_title(discRow.cast(), UI.escape(disc.fileName))
        } else if draft.existingDiscName != nil {
            adw_preferences_row_set_title(discRow.cast(), "The game’s disc")
        } else {
            adw_preferences_row_set_title(discRow.cast(), "No disc yet")
        }
        discRow.setClass("dim-label", !draft.hasDisc)
        gtk_button_set_label(discButton.cast(), draft.hasDisc ? "Replace…" : "Choose…")
        laterNote.setVisible(!draft.hasDisc)
    }

    private func showMachine() {
        let model = draft.game.model
        if let index = MachineModel.allCases.firstIndex(of: model), Int(adw_combo_row_get_selected(modelRow.cast())) != index {
            adw_combo_row_set_selected(modelRow.cast(), guint(index))
        }
        let choices = model.ramChoices
        adw_combo_row_set_model(memoryRow.cast(), UI.stringList(["As the model usually has"] + choices.map(AppSettings.ramLabel)))
        adw_combo_row_set_selected(memoryRow.cast(), guint(draft.game.ramKB.flatMap { choices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0))
    }

    /// The application's picker (from the disc's), or its name typed in;
    /// or the command.
    private func showStart() {
        let current = UI.text(of: applicationEntryRow)
        adw_combo_row_set_model(applicationRow.cast(), UI.stringList(applications))
        if let index = applications.firstIndex(of: current) {
            adw_combo_row_set_selected(applicationRow.cast(), guint(index))
        }
        applicationRow.setVisible(startChoice == .application && !applications.isEmpty)
        applicationEntryRow.setVisible(startChoice == .application && applications.isEmpty)
        commandRow.setVisible(startChoice == .type)
    }

    private func updateSaveButton() {
        let title = UI.text(of: titleRow).trimmingCharacters(in: .whitespaces)
        saveButton.setSensitive(!title.isEmpty && !saving)
    }

    // MARK: Files

    private func chooseDisc() {
        FileDialogs.open(parent: parent, title: "The Game’s Disc Image", filters: [MachineController.discFilter]) { [weak self] url in
            _ = self?.take([url])
        }
    }

    private func chooseCover() {
        FileDialogs.open(parent: parent, title: "A Cover Picture", filters: [GameLibrary.coverFilter]) { [weak self] url in
            _ = self?.take([url])
        }
    }

    /// A disc image or picture dropped on (or chosen in) the dialog.
    private func take(_ urls: [URL]) -> Bool {
        let discURL = urls.first(where: MyGames.isDiscName)
        let coverURL = urls.first(where: MyGames.isCoverName)
        guard discURL != nil || coverURL != nil else { return false }
        if let coverURL {
            do {
                _ = try MyGames.checkCover(at: coverURL)
                draft.newCover = coverURL
                Covers.forget(coverURL)
                showCover()
            } catch {
                Alerts.show(error, parent: parent)
            }
        }
        if let discURL {
            do {
                let disc = try MyGames.readDisc(at: discURL)
                let hadDisc = draft.hasDisc
                draft.disc = disc
                applications = disc.applications
                if draft.isNew && !hadDisc {
                    switch disc.suggestedStart {
                    case .application(let name):
                        UI.setText(editable: applicationEntryRow, name)
                        gtk_check_button_set_active(startChecks[StartChoice.application.rawValue].cast(), 1)
                    case .boot:
                        gtk_check_button_set_active(startChecks[StartChoice.boot.rawValue].cast(), 1)
                    default: break
                    }
                    // A cover-first game: its disc says more about it.
                    let title = UI.text(of: titleRow)
                    if title.isEmpty || title == draft.newCover?.deletingPathExtension().lastPathComponent {
                        UI.setText(editable: titleRow, disc.suggestedTitle)
                        if UI.text(of: yearRow).isEmpty, let year = disc.suggestedYear { UI.setText(editable: yearRow, String(year)) }
                    }
                }
                showStart()
                showDisc()
            } catch {
                Alerts.show(error, parent: parent)
            }
        }
        return true
    }

    // MARK: Saving

    private func optional(_ row: Widget) -> String? {
        let text = UI.text(of: row).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private func save() {
        guard !saving, let title = optional(titleRow) else { return }
        draft.game.title = title
        draft.game.publisher = optional(publisherRow)
        draft.game.year = Int(UI.text(of: yearRow).trimmingCharacters(in: .whitespaces))
        let application: String
        if applications.isEmpty {
            application = UI.text(of: applicationEntryRow).trimmingCharacters(in: .whitespaces)
        } else {
            let index = Int(adw_combo_row_get_selected(applicationRow.cast()))
            application = applications.indices.contains(index) ? applications[index] : ""
        }
        draft.game.start = switch startChoice {
        case .application: application.isEmpty ? .insertOnly : .application(application)
        case .boot: .boot
        case .insertOnly: .insertOnly
        case .type: .type(UI.text(of: commandRow).trimmingCharacters(in: .whitespaces))
        }
        let buffer = gtk_text_view_get_buffer(notes.cast())
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = String(gOwned: gtk_text_buffer_get_text(buffer, &start, &end, 0)) ?? ""
        draft.game.notes = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        saving = true
        let draft = draft
        Task {
            let done = await library.save(draft)
            saving = false
            if done {
                saved = true
                if let cover = draft.newCover { Covers.forget(cover) }
                if let url = library.myGames.coverURL(draft.game) { Covers.forget(url) }
                adw_dialog_close(dialog.cast())
            }
        }
    }

    private func close() {
        adw_dialog_close(dialog.cast())
    }
}
