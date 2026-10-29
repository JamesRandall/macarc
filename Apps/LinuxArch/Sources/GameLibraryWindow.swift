import ArchimedesCore
import CGtk
import Foundation

/// The shelves of the game library, one to a tab.
enum ShelfTab: String, CaseIterable, Identifiable {
    /// The Archimedes Top 25, from the Archimedes Archive.
    case classics
    /// The user's own.
    case myGames

    var id: Self { self }

    var name: String {
        switch self {
        case .classics: "Archimedes Classics"
        case .myGames: "My Games"
        }
    }
}

/// The Game Library: the Archimedes Classics (a Top 25, with a book for the
/// Archimedes Archive their discs come from) and My Games, in tabs, as
/// covers on a shelf with a game's details beside them. The Classics' discs
/// are downloaded from the archive in the user's browser; LinuxArch never
/// downloads them itself. Drop disc images and cover pictures on it to add
/// games: the Classics' discs go to them, anything else to My Games. (The
/// Mac app's, after LinuxBeeb's.)
@MainActor
final class GameLibraryWindow {
    static let title = "Game Library"
    private static var current: GameLibraryWindow?
    static var isOpen: Bool { current != nil }

    /// Opens the game library, or brings it to the front.
    @discardableResult
    static func show() -> GameLibraryWindow {
        if let current {
            current.present()
            return current
        }
        let window = GameLibraryWindow()
        current = window
        window.present()
        return window
    }

    let window: Widget
    private let library = GameLibrary.shared
    private let classics = ClassicsLibrary.shared
    private static let tabKey = "libraryTab"
    private var tab = ShelfTab(rawValue: Preferences.standard.string(forKey: tabKey) ?? "") ?? .classics {
        didSet {
            Preferences.standard.set(tab.rawValue, forKey: Self.tabKey)
            selection = nil
            showShelf()
        }
    }
    /// The selected tile's ID.
    private var selection: String? {
        didSet { showDetail() }
    }
    private let split: Widget
    private let tabs: Widget
    private let heading: Widget
    private let banners: Widget
    private let grid: Widget
    private let footer: Widget
    private let detail: Widget
    private var tileIDs: [String] = []
    /// The tiles are being replaced: their selection isn't the user's.
    private var rebuilding = false
    /// A click or key is being handled: a selection is the user's. (GTK
    /// also selects the tile that's given the focus when the window opens,
    /// or when the shelf changes, which shouldn't show its details.)
    private var userSelecting = false
    private var draftShowing = false
    private var arrivalsSeen = ClassicsLibrary.shared.arrivals

    static let tileWidth: Int32 = 168
    static let coverHeight: Int32 = 210
    private static func classicID(_ game: ClassicGame) -> String { "classic-\(game.id)" }
    private static func myID(_ game: PersonalGame) -> String { "my-\(game.id.uuidString)" }
    private static let archiveID = "archive"
    private static let addID = "add"

    private init() {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_title(window.cast(), Self.title)
        gtk_window_set_default_size(window.cast(), 1040, 780)

        tabs = adw_toggle_group_new()!
        for tab in ShelfTab.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, tab.rawValue)
            adw_toggle_set_label(toggle, tab.name)
            adw_toggle_group_add(tabs.cast(), toggle)
        }
        tabs.setTooltip("Choose a shelf")
        heading = UI.vbox(spacing: 4)
        banners = UI.vbox(spacing: 8)
        grid = gtk_flow_box_new()!
        footer = UI.vbox(spacing: 6)
        detail = UI.vbox(spacing: 14)
        split = adw_overlay_split_view_new()!
        build()
        observeLibrary()

        onSignalReturning(window, "close-request") {
            Self.current = nil
            return false
        }
        onNotify(window, "is-active") { [weak self] in
            if let self, gtk_window_is_active(self.window.cast()) != 0 {
                self.classics.appBecameActive()
            }
        }
    }

    func present() {
        gtk_window_present(window.cast())
    }

    // MARK: Building

    private func build() {
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(header.cast(), tabs)
        adw_toggle_group_set_active_name(tabs.cast(), tab.rawValue)
        onNotify(tabs, "active-name") { [weak self] in
            guard let self, let name = String(gBorrowed: adw_toggle_group_get_active_name(self.tabs.cast())),
                  let tab = ShelfTab(rawValue: name), tab != self.tab else { return }
            self.tab = tab
        }
        let machine = UI.iconButton("computer-symbolic", tooltip: "Open an Archimedes window, to use without a game from the shelf") {
            if let machine = MachineController.frontmost?.window {
                machine.present()
            } else {
                LinuxArchApp.shared.newWindow()
            }
        }
        adw_header_bar_pack_start(header.cast(), machine)
        let details = gtk_toggle_button_new()!
        gtk_button_set_icon_name(details.cast(), "sidebar-show-right-symbolic")
        details.setTooltip("Show or hide the details of the selected game")
        adw_header_bar_pack_end(header.cast(), details)
        adw_header_bar_pack_end(header.cast(), UI.iconButton("list-add-symbolic",
            tooltip: "Add disc images and cover pictures: the Classics’ discs, or your own games") { [weak self] in
            guard let self else { return }
            self.library.chooseFiles(parent: self.window)
        })

        // The shelf: a heading, any notices, the books, and the credit.
        gtk_flow_box_set_selection_mode(grid.cast(), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_activate_on_single_click(grid.cast(), 0)
        gtk_flow_box_set_homogeneous(grid.cast(), 1)
        gtk_flow_box_set_column_spacing(grid.cast(), 20)
        gtk_flow_box_set_row_spacing(grid.cast(), 20)
        gtk_flow_box_set_max_children_per_line(grid.cast(), 12)
        grid.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START)
        grid.addClass("shelf")
        onSignal(grid, "selected-children-changed") { [weak self] in
            guard let self, !self.rebuilding else { return }
            guard self.userSelecting else {
                self.showSelection()
                return
            }
            let selected = gtk_flow_box_get_selected_children(self.grid.cast())
            let child = selected?.pointee.data
            g_list_free(selected)
            let index = child.map { Int(gtk_flow_box_child_get_index($0.cast())) }
            let id = index.flatMap { self.tileIDs.indices.contains($0) ? self.tileIDs[$0] : nil }
            if id != self.selection {
                self.selection = id
                if id != nil && id != Self.addID { adw_overlay_split_view_set_show_sidebar(self.split.cast(), 1) }
            }
        }
        for name in ["pressed", "released"] {
            let click = gtk_gesture_click_new()!
            gtk_event_controller_set_propagation_phase(click.opaque, GTK_PHASE_CAPTURE)
            onClick(click, name) { [weak self] _, _, _ in self?.noteUserSelecting() }
            grid.addController(click)
        }
        let gridKeys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(gridKeys.opaque, GTK_PHASE_CAPTURE)
        onKey(gridKeys, "key-pressed") { [weak self] _, _, _ in
            self?.noteUserSelecting()
            return false
        }
        grid.addController(gridKeys)
        let activated: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, child, data in
            let window = Unmanaged<GameLibraryWindow>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let child else { return }
                let index = Int(gtk_flow_box_child_get_index(child.cast()))
                if window.tileIDs.indices.contains(index) { window.primaryAction(window.tileIDs[index]) }
            }
        }
        la_signal_connect(grid.raw, "child-activated", unsafeBitCast(activated, to: GCallback.self),
                          Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        let shelf = UI.vbox(spacing: 20, [heading, banners, grid, footer])
        shelf.setMargins(24)
        let content = UI.scrolled(shelf)

        // The details, in a sidebar that slides in.
        let detailScroll = UI.scrolled(detail)
        detail.setMargins(16)
        gtk_widget_set_size_request(detailScroll, 320, -1)
        adw_overlay_split_view_set_content(split.cast(), content)
        adw_overlay_split_view_set_sidebar(split.cast(), detailScroll)
        adw_overlay_split_view_set_sidebar_position(split.cast(), GTK_PACK_END)
        adw_overlay_split_view_set_show_sidebar(split.cast(), 0)
        adw_overlay_split_view_set_min_sidebar_width(split.cast(), 320)
        adw_overlay_split_view_set_max_sidebar_width(split.cast(), 360)
        _ = g_object_bind_property(details.raw, "active", split.raw, "show-sidebar",
                                   GBindingFlags(rawValue: 1 | 2) /* bidirectional, sync-create */)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), split)
        adw_window_set_content(window.cast(), toolbar)
        // A narrow window has the details over the shelf, not beside it.
        let narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 700sp"))!
        la_breakpoint_set_bool(narrow, split.raw, "collapsed", 1)
        adw_window_add_breakpoint(window.cast(), narrow)
        gtk_widget_set_size_request(window, 360, 400)

        // Classics' discs go to the Classics; anything else becomes one of
        // My Games.
        acceptFileDrops(on: window) { [weak self] urls in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) || ClassicsLibrary.isCandidateName($0) }
            self?.library.addFiles(wanted)
            return !wanted.isEmpty
        }
        // Escape hides the details.
        let keys = gtk_event_controller_key_new()!
        onKey(keys, "key-pressed") { [weak self] keyval, _, _ in
            guard let self, keyval == UInt32(GDK_KEY_Escape),
                  adw_overlay_split_view_get_show_sidebar(self.split.cast()) != 0 else { return false }
            adw_overlay_split_view_set_show_sidebar(self.split.cast(), 0)
            return true
        }
        window.addController(keys)
    }

    // MARK: The shelf

    private func observeLibrary() {
        observe(self) { [weak self] in
            guard let self else { return }
            // What the shelf shows depends on all of these.
            _ = (self.classics.installed, self.classics.pending, self.classics.importing, self.classics.justInstalled,
                 self.classics.watchState, self.classics.autoDetect, self.library.personalGames)
            self.showShelf()
        }
        // A game to fill in the details of: show it, on My Games.
        observe(self) { [weak self] in
            guard let self else { return }
            _ = self.library.drafts.first?.id
            after(0) { [weak self] in self?.presentNextDraft() }
        }
        // A Classic's disc arriving: show it.
        observe(self) { [weak self] in
            guard let self else { return }
            let arrivals = self.classics.arrivals
            guard arrivals != self.arrivalsSeen else { return }
            self.arrivalsSeen = arrivals
            after(0) { [weak self] in
                guard let self else { return }
                if self.tab != .classics { adw_toggle_group_set_active_name(self.tabs.cast(), ShelfTab.classics.rawValue) }
                self.present()
            }
        }
    }

    /// Shows the first game waiting for its details, unless one's showing.
    private func presentNextDraft() {
        guard !draftShowing, let draft = library.drafts.first else { return }
        draftShowing = true
        if tab != .myGames {
            adw_toggle_group_set_active_name(tabs.cast(), ShelfTab.myGames.rawValue)
        }
        GameDetailsDialog.present(draft: draft, parent: window) { [weak self] in
            self?.draftShowing = false
            self?.presentNextDraft()
        }
    }

    private func showShelf() {
        UI.removeAll(heading)
        if tab == .myGames {
            let text = UI.vbox(spacing: 4, [
                UI.label("My Games", classes: ["shelf-title"]),
                UI.label("Your Archimedes games, ready to play. Drag in floppy disc images and cover pictures, in either order or together.",
                         classes: ["shelf-subtitle", "dim-label"], wrap: true),
            ])
            text.expand(horizontally: true)
            let add = UI.button("Add Games…") { [weak self] in
                guard let self else { return }
                self.library.chooseFiles(parent: self.window)
            }
            add.align(vertical: GTK_ALIGN_CENTER)
            UI.append(heading, UI.hbox(spacing: 12, [text, add]))
        } else {
            UI.append(heading, UI.label("Archimedes Classics", classes: ["shelf-title"]))
            UI.append(heading, UI.label("Twenty-five of the Archimedes’ best games, from the Archimedes Archive, ready to discover and play.",
                                        classes: ["shelf-subtitle", "dim-label"], wrap: true))
        }
        showBanners()
        showTiles()
        showFooter()
        showDetail()
    }

    private func banner(icon: String, _ message: String, _ actions: [Widget]) -> Widget {
        let text = UI.label(message, wrap: true)
        text.expand(horizontally: true)
        let image = UI.image(icon: icon, size: 24)
        image.addClass("dim-label")
        let row = UI.hbox(spacing: 12, [image, text] + actions, classes: ["banner-card"])
        for action in actions { action.align(vertical: GTK_ALIGN_CENTER) }
        return row
    }

    private func showBanners() {
        UI.removeAll(banners)
        guard tab == .classics else { return }
        if case .noAccess = classics.watchState {
            UI.append(banners, banner(icon: "folder-symbolic",
                "LinuxArch can’t look in \(classics.downloadFolder.lastPathComponent) for downloaded discs. Choose another folder in Preferences. You can always add discs with Add Games… or by dragging them here.",
                [UI.button("Preferences…") { [weak self] in PreferencesDialog.present(parent: self?.window, page: .general) }]))
        } else if !classics.pending.isEmpty && classics.autoDetect != true {
            UI.append(banners, banner(icon: "folder-download-symbolic",
                "To add games automatically, allow LinuxArch to look for downloaded disc images. You can always add them by hand.",
                [UI.button("Look for Downloads") { [weak self] in self?.classics.autoDetect = true }]))
        }
    }

    private func showTiles() {
        let selected = selection
        var ids: [String] = []
        var tiles: [Widget] = []
        switch tab {
        case .classics:
            for game in classics.catalogue.games {
                ids.append(Self.classicID(game))
                tiles.append(tile(game))
            }
            ids.append(Self.archiveID)
            tiles.append(archiveTile())
        case .myGames:
            for game in library.personalGames {
                ids.append(Self.myID(game))
                tiles.append(tile(game))
            }
            ids.append(Self.addID)
            tiles.append(addTile())
        }
        rebuilding = true
        defer { rebuilding = false }
        gtk_flow_box_remove_all(grid.cast())
        tileIDs = ids
        for tile in tiles {
            gtk_flow_box_append(grid.cast(), tile)
        }
        if let selected, !ids.contains(selected) {
            // It's gone (removed): so are its details.
            after(0) { [weak self] in self?.selection = nil }
        }
        showSelection()
    }

    private func noteUserSelecting() {
        userSelecting = true
        after(0) { [weak self] in self?.userSelecting = false }
    }

    /// Selects the tile that's selected (GTK may have selected another).
    private func showSelection() {
        rebuilding = true
        defer { rebuilding = false }
        if let selection, let index = tileIDs.firstIndex(of: selection),
           let child = gtk_flow_box_get_child_at_index(grid.cast(), Int32(index)) {
            gtk_flow_box_select_child(grid.cast(), child)
        } else {
            gtk_flow_box_unselect_all(grid.cast())
        }
    }

    private func tileBox(cover: Widget, title: String, number: Int?, status: Widget) -> Widget {
        let coverBox = UI.vbox(spacing: 0, [cover])
        gtk_widget_set_size_request(coverBox, Self.tileWidth, Self.coverHeight)
        cover.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        coverBox.expand(vertically: false)
        var titleLine: [Widget] = []
        if let number {
            titleLine.append(UI.label("\(number)", classes: ["rank", "numeric"]))
        }
        let name = UI.label(title, classes: ["tile-title"])
        gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_END)
        // (No wider than the tile, whatever the title.)
        gtk_label_set_max_width_chars(name.cast(), 17)
        titleLine.append(name)
        let line = UI.hbox(spacing: 6, titleLine)
        line.align(horizontal: GTK_ALIGN_CENTER)
        status.align(horizontal: GTK_ALIGN_CENTER)
        let box = UI.vbox(spacing: 8, [coverBox, UI.vbox(spacing: 3, [line, status])], classes: ["tile"])
        gtk_widget_set_size_request(box, Self.tileWidth + 16, -1)
        // (The shelf spreads its columns across the window.)
        box.align(horizontal: GTK_ALIGN_CENTER)
        return box
    }

    private func status(_ text: String, icon: String? = nil, classes: [String] = []) -> Widget {
        var parts: [Widget] = []
        if let icon { parts.append(UI.image(icon: icon, size: 12)) }
        let label = UI.label(text, classes: ["caption"])
        gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(label.cast(), 24)
        parts.append(label)
        return UI.hbox(spacing: 4, parts, classes: classes)
    }

    private func link(_ text: String, icon: String, tooltip: String? = nil, _ action: @escaping Handler) -> Widget {
        let content = adw_button_content_new()!
        adw_button_content_set_icon_name(content.cast(), icon)
        adw_button_content_set_label(content.cast(), text)
        let button = gtk_button_new()!
        gtk_button_set_child(button.cast(), content)
        for name in ["flat", "caption", "get-link"] { button.addClass(name) }
        button.setTooltip(tooltip)
        onSignal(button, "clicked", action)
        return button
    }

    /// One of the Classics on the shelf: its cover, rank, and what's next.
    private func tile(_ game: ClassicGame) -> Widget {
        let state = classics.state(of: game)
        let status: Widget
        if classics.justInstalled == game.id {
            status = self.status("Added to your library", icon: "object-select-symbolic", classes: ["ready"])
        } else {
            switch state {
            case .notInstalled:
                status = link("Get", icon: "folder-download-symbolic", tooltip: "Get \(game.title) from the Archimedes Archive") { [weak self] in
                    self?.classics.get(game)
                }
            case .waiting:
                let have = classics.haveDiscs(game)
                status = self.status(have > 0 ? "\(have) of \(game.discs.count) discs…" : "Waiting for download…",
                                     icon: "document-open-recent-symbolic", classes: ["waiting"])
            case .importing:
                status = self.status("Adding…", classes: ["waiting"])
            case .partial(let have, let of):
                status = self.status("\(have) of \(of) discs", classes: ["waiting"])
            case .installed:
                status = self.status("Ready to play", icon: "object-select-symbolic", classes: ["ready"])
            }
        }
        let box = tileBox(cover: Covers.cover(for: game, height: Self.coverHeight, installed: state == .installed),
                          title: game.title, number: game.rank, status: status)
        box.setTooltip("#\(game.rank) \(game.title)" + (game.editionLabel.map { " (\($0))" } ?? ""))
        // Right-click: play, or get it.
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click.cast(), 3)
        onClick(click, "pressed") { [weak self] _, x, y in
            guard let self else { return }
            let buttons: [(String, Handler)] = self.classics.state(of: game) == .installed ? [
                ("Play", { [weak self] in self?.play(game) }),
                ("Reveal Discs", { [weak self] in self?.classics.reveal(game) }),
                ("Remove…", { [weak self] in self?.classics.remove(game) }),
            ] : [
                ("Get from the Archimedes Archive", { [weak self] in self?.classics.get(game) }),
                ("Add Discs…", { [weak self] in
                    guard let self else { return }
                    self.classics.chooseAndImport(for: game, parent: self.window)
                }),
            ]
            Self.popupMenu(buttons, on: box, x: x, y: y)
        }
        box.addController(click)
        return box
    }

    private func archiveTile() -> Widget {
        let box = tileBox(cover: Covers.archiveCover(classics.catalogue.archive, height: Self.coverHeight), title: "Archimedes Archive",
                          number: nil, status: status("Explore the archive ↗", classes: ["accent"]))
        box.setTooltip(classics.catalogue.archive.pitch)
        return box
    }

    /// One of My Games on the shelf. Dropping a disc or picture on it gives
    /// it that disc or cover.
    private func tile(_ game: PersonalGame) -> Widget {
        let status = game.discFile == nil
            ? self.status("No disc yet: drop one here", icon: "media-optical-symbolic", classes: ["dim-label"])
            : self.status("Ready to play", icon: "object-select-symbolic", classes: ["ready"])
        let box = tileBox(cover: Covers.cover(for: game, height: Self.coverHeight), title: game.title, number: nil, status: status)
        box.setTooltip(game.discFile == nil ? "\(game.title): drop its disc image here" : "\(game.title): double-click to play; drop a picture here for its cover")
        acceptFileDrops(on: box) { [weak self] urls in
            self?.library.attach(urls, to: game) ?? false
        }
        // Right-click: play, edit, files, remove.
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click.cast(), 3)
        onClick(click, "pressed") { [weak self] _, x, y in
            guard let self else { return }
            var buttons: [(String, Handler)] = []
            if game.discFile != nil { buttons.append(("Play", { Player.play(game) })) }
            buttons += [
                ("Edit…", { [weak self] in self?.library.edit(game) }),
                (game.discFile == nil ? "Choose Disc…" : "Replace Disc…", { [weak self] in
                    guard let self else { return }
                    self.library.chooseDisc(for: game, parent: self.window)
                }),
                (game.coverFile == nil ? "Add Cover…" : "Change Cover…", { [weak self] in
                    guard let self else { return }
                    self.library.chooseCover(for: game, parent: self.window)
                }),
                ("Remove…", { [weak self] in self?.library.remove(game) }),
            ]
            Self.popupMenu(buttons, on: box, x: x, y: y)
        }
        box.addController(click)
        return box
    }

    /// A column of buttons in a popover at a point, as a context menu.
    private static func popupMenu(_ buttons: [(String, Handler)], on widget: Widget, x: Double, y: Double) {
        let popover = gtk_popover_new()!
        let column = UI.vbox(spacing: 2)
        for (title, action) in buttons {
            UI.append(column, UI.button(title, classes: ["flat"]) {
                gtk_popover_popdown(popover.cast())
                action()
            })
        }
        gtk_popover_set_child(popover.cast(), column)
        gtk_widget_set_parent(popover, widget)
        var point = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover.cast(), &point)
        onSignal(popover, "closed") { after(0) { gtk_widget_unparent(popover) } }
        gtk_popover_popup(popover.cast())
    }

    /// The empty box at the end of My Games: drop discs and pictures on it,
    /// or activate it to choose them.
    private func addTile() -> Widget {
        let plus = UI.image(icon: "list-add-symbolic", size: 32)
        let text = UI.label("Drop disc images or cover pictures here", classes: ["caption", "dim-label"], wrap: true, xalign: 0.5)
        gtk_label_set_max_width_chars(text.cast(), 12)
        gtk_label_set_justify(text.cast(), GTK_JUSTIFY_CENTER)
        let inner = UI.vbox(spacing: 8, [plus, text])
        inner.align(vertical: GTK_ALIGN_CENTER)
        inner.expand(vertically: true)
        inner.setMargins(12)
        let well = UI.vbox(spacing: 0, [inner], classes: ["add-tile"])
        gtk_widget_set_size_request(well, Int32(Double(Self.coverHeight) * 0.7), Self.coverHeight)
        let box = tileBox(cover: well, title: "Add a Game", number: nil, status: UI.label(" ", classes: ["caption"]))
        acceptFileDrops(on: box) { [weak self] urls in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            self?.library.addFiles(wanted)
            return !wanted.isEmpty
        }
        return box
    }

    private func showFooter() {
        UI.removeAll(footer)
        UI.append(footer, UI.separator())
        if tab == .classics {
            UI.append(footer, UI.label("Disc images courtesy of the Archimedes Archive (arcarc.top), downloaded in your browser. The archive and its contributors have spent years preserving Archimedes software for emulators and original machines. LinuxArch is an independent emulator and is not affiliated with the archive.",
                                       classes: ["dim-label"], wrap: true))
            let link = gtk_link_button_new_with_label("https://arcarc.top/", "About the Archimedes Archive")!
            link.align(horizontal: GTK_ALIGN_START)
            UI.append(footer, link)
        } else if library.personalGames.isEmpty {
            UI.append(footer, UI.label("Each game keeps its own copy of its disc, the machine it plays on (an A3000 with RISC OS 3, say, or RISC OS 2 for older games) and how it starts: from the disc’s !Boot, with a command at the command line, or with the disc just put in for you to open. Double-click a game to play it.",
                                       classes: ["dim-label"], wrap: true))
        } else {
            UI.removeAll(footer)
        }
    }

    // MARK: Selection

    /// Shows a shelf.
    func show(tab: ShelfTab) {
        adw_toggle_group_set_active_name(tabs.cast(), tab.rawValue)
    }

    /// Selects a tile (as clicking it does), showing its details.
    func select(index: Int) {
        userSelecting = true
        defer { userSelecting = false }
        if let child = gtk_flow_box_get_child_at_index(grid.cast(), Int32(index)) {
            gtk_flow_box_select_child(grid.cast(), child)
        }
    }

    private var selectedClassic: ClassicGame? {
        classics.catalogue.games.first { Self.classicID($0) == selection }
    }

    private var selectedPersonalGame: PersonalGame? {
        library.personalGames.first { Self.myID($0) == selection }
    }

    private func play(_ game: ClassicGame) {
        Player.play(game)
    }

    /// Enter or a double-click on a tile: its main action.
    private func primaryAction(_ id: String) {
        if id == Self.addID {
            library.chooseFiles(parent: window)
            return
        }
        adw_overlay_split_view_set_show_sidebar(split.cast(), 1)
        if id == Self.archiveID {
            openURI(classics.catalogue.archive.url.absoluteString, parent: window)
        } else if let game = library.personalGames.first(where: { Self.myID($0) == id }) {
            if game.discFile != nil { Player.play(game) }
        } else if let game = classics.catalogue.games.first(where: { Self.classicID($0) == id }) {
            // (A double click never starts a download: Enter does, as the
            // Mac app's Return.)
            switch classics.state(of: game) {
            case .notInstalled, .partial: classics.get(game)
            case .installed: play(game)
            default: break
            }
        }
    }

    private func showDetail() {
        UI.removeAll(detail)
        if let game = selectedClassic {
            LibraryDetails.classic(game, into: detail, parent: window)
        } else if selection == Self.archiveID {
            LibraryDetails.archive(classics.catalogue.archive, into: detail, parent: window)
        } else if let game = selectedPersonalGame {
            LibraryDetails.personal(game, into: detail, parent: window)
        } else {
            UI.append(detail, UI.label("Choose a game to see its details.", classes: ["dim-label"], wrap: true))
        }
    }
}

// MARK: Covers

/// Covers for the game library: the Classics' (installed with the app),
/// My Games' own, and typographic ones. (LinuxBeeb's.)
@MainActor
enum Covers {
    private static var textures: [String: OpaquePointer] = [:]

    /// A picture file as a texture, kept (covers are shown again and again).
    static func texture(_ url: URL) -> OpaquePointer? {
        if let texture = textures[url.path] { return texture }
        guard let file = g_file_new_for_path(url.path) else { return nil }
        defer { g_object_unref(file.raw) }
        guard let texture = gdk_texture_new_from_file(file, nil) else { return nil }
        textures[url.path] = texture.opaque
        return texture.opaque
    }

    /// Forgets a picture (a cover's been replaced).
    static func forget(_ url: URL) {
        if let texture = textures.removeValue(forKey: url.path) { g_object_unref(texture.raw) }
    }

    /// A picture `height` high (as wide as its proportions say, up to
    /// `width`).
    static func picture(_ url: URL, width: Int32, height: Int32, classes: [String] = ["cover"]) -> Widget? {
        guard let texture = texture(url) else { return nil }
        let picture = gtk_picture_new_for_paintable(texture)!
        gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(picture.cast(), 1)
        let aspect = Double(gdk_texture_get_width(texture.cast())) / max(1, Double(gdk_texture_get_height(texture.cast())))
        let shownWidth = min(Double(width), Double(height) * aspect)
        gtk_widget_set_size_request(picture, Int32(shownWidth), Int32(shownWidth / aspect))
        for name in classes { picture.addClass(name) }
        // A picture wants to be as big as its texture: no wider than shown.
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(clamp.cast(), Int32(shownWidth))
        adw_clamp_set_tightening_threshold(clamp.cast(), Int32(shownWidth))
        adw_clamp_set_child(clamp.cast(), picture)
        clamp.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        return clamp
    }

    /// A Classic's cover, or its title on a plain one. Not in the library
    /// yet: a touch darker, still in full colour.
    static func cover(for game: ClassicGame, height: Int32, installed: Bool = true) -> Widget {
        if let url = AppPaths.resource("Covers/\(game.id).jpg"),
           let picture = picture(url, width: height, height: height, classes: installed ? ["cover"] : ["cover", "not-installed"]) {
            return picture
        }
        var lines = [UI.label(game.title.uppercased(), classes: ["cover-title"], wrap: true, xalign: 0.5)]
        if let publisher = game.publisher {
            lines.append(UI.label(publisher, classes: ["cover-caption"], xalign: 0.5))
        }
        return placeholder(lines, height: height, style: "placeholder-cover")
    }

    /// One of My Games' covers, or its title until it has one.
    static func cover(for game: PersonalGame, height: Int32) -> Widget {
        if let url = GameLibrary.shared.myGames.coverURL(game), let picture = picture(url, width: height, height: height) {
            return picture
        }
        var lines = [UI.label(game.title.uppercased(), classes: ["cover-title"], wrap: true, xalign: 0.5)]
        if let publisher = game.publisher {
            lines.append(UI.label(publisher, classes: ["cover-caption"], xalign: 0.5))
        }
        lines.append(UI.label("Drop a cover here", classes: ["cover-caption", "caption"], xalign: 0.5))
        return placeholder(lines, height: height, style: "placeholder-cover")
    }

    /// The archive's book: typographic, in the Archimedes' colours, with no
    /// third-party logo.
    static func archiveCover(_ archive: ClassicsArchive, height: Int32) -> Widget {
        let bands = UI.hbox(spacing: 3, ["green", "cyan", "blue", "orange", "yellow"].map { colour in
            let band = UI.box(GTK_ORIENTATION_HORIZONTAL, classes: ["band", colour])
            band.expand(horizontally: true)
            return band
        })
        bands.setMargins(top: 10)
        let icon = UI.image(icon: "accessories-dictionary-symbolic", size: 30)
        icon.addClass("archive-green")
        icon.align(horizontal: GTK_ALIGN_START)
        let text = UI.vbox(spacing: 6, [
            icon,
            UI.label(archive.title, classes: ["archive-title"], wrap: true),
            UI.label("arcarc.top", classes: ["archive-green", "monospace", "caption"]),
            UI.label("Thousands more titles", classes: ["cover-caption"]),
        ])
        text.expand(vertically: true)
        text.align(vertical: GTK_ALIGN_END)
        let box = UI.vbox(spacing: 0, [bands, text], classes: ["archive-cover"])
        gtk_widget_set_size_request(box, Int32(Double(height) * 0.7), height)
        box.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        return box
    }

    private static func placeholder(_ lines: [Widget], height: Int32, style: String) -> Widget {
        // The Archimedes' function keys, as a band.
        let bands = UI.vbox(spacing: 3, (0..<3).map { _ in UI.box(GTK_ORIENTATION_HORIZONTAL, classes: ["band"]) })
        bands.setMargins(top: 8)
        let inner = UI.vbox(spacing: 8, lines)
        inner.align(vertical: GTK_ALIGN_CENTER)
        inner.expand(vertically: true)
        let box = UI.vbox(spacing: 0, [bands, inner], classes: [style])
        gtk_widget_set_size_request(box, Int32(Double(height) * 0.7), height)
        box.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        return box
    }
}

// MARK: Details

/// The game library's details panel: a Classic's, the archive's, or one of
/// My Games'.
@MainActor
enum LibraryDetails {
    private static func heading(_ title: String, _ lines: [String]) -> Widget {
        let box = UI.vbox(spacing: 4, [UI.label(title, classes: ["title-2"], wrap: true)])
        for line in lines {
            UI.append(box, UI.label(line, classes: ["dim-label"], wrap: true))
        }
        return box
    }

    /// A big button, the panel's main action.
    private static func prominent(_ label: String, icon: String? = nil, _ action: @escaping Handler) -> Widget {
        let button = gtk_button_new()!
        if let icon {
            let content = adw_button_content_new()!
            adw_button_content_set_icon_name(content.cast(), icon)
            adw_button_content_set_label(content.cast(), label)
            gtk_button_set_child(button.cast(), content)
        } else {
            gtk_button_set_label(button.cast(), label)
        }
        button.addClass("pill")
        button.addClass("suggested-action")
        onSignal(button, "clicked", action)
        return button
    }

    /// Smaller actions, in a row of links.
    private static func links(_ items: [(String, Handler)]) -> Widget {
        let row = UI.hbox(spacing: 0)
        for (title, action) in items {
            UI.append(row, UI.button(title, classes: ["flat", "link-button"], action))
        }
        return row
    }

    /// Two columns of facts: what, and what it is.
    private static func facts(_ rows: [(String, String, Bool)]) -> Widget {
        let grid = gtk_grid_new()!
        gtk_grid_set_column_spacing(grid.cast(), 10)
        gtk_grid_set_row_spacing(grid.cast(), 6)
        for (index, (name, value, monospace)) in rows.enumerated() {
            let label = UI.label(name, classes: ["dim-label"])
            label.align(vertical: GTK_ALIGN_START)
            let text = UI.label(value, classes: monospace ? ["monospace"] : [], wrap: true, selectable: monospace)
            text.expand(horizontally: true)
            gtk_grid_attach(grid.cast(), label, 0, Int32(index), 1, 1)
            gtk_grid_attach(grid.cast(), text, 1, Int32(index), 1, 1)
        }
        return grid
    }

    private static func web(_ title: String, _ url: URL) -> Widget {
        let link = gtk_link_button_new_with_label(url.absoluteString, title)!
        link.align(horizontal: GTK_ALIGN_START)
        return link
    }

    private static func coverBox(_ cover: Widget) -> Widget {
        let box = UI.vbox(spacing: 0, [cover])
        box.align(horizontal: GTK_ALIGN_CENTER)
        box.setMargins(bottom: 4)
        return box
    }

    private static func spinner(_ text: String) -> Widget {
        let spinner = adw_spinner_new()!
        gtk_widget_set_size_request(spinner, 16, 16)
        return UI.hbox(spacing: 8, [spinner, UI.label(text, classes: ["dim-label"])])
    }

    private static func fill(_ box: Widget, _ widgets: [Widget]) {
        for widget in widgets { UI.append(box, widget) }
    }

    // MARK: A Classic

    static func classic(_ game: ClassicGame, into box: Widget, parent: Widget) {
        var lines: [String] = []
        if let edition = game.editionLabel { lines.append(edition) }
        lines.append("#\(game.rank) of the Archimedes Top 25")
        var widgets = [coverBox(Covers.cover(for: game, height: 260)), heading(game.title, lines), actions(for: game, parent: parent),
                       UI.label(branded(game.description), wrap: true)]
        if let hint = game.hint {
            let text = UI.label(branded(hint), classes: ["dim-label"], wrap: true)
            text.expand(horizontally: true)
            let icon = UI.image(icon: "dialog-information-symbolic")
            icon.align(vertical: GTK_ALIGN_START)
            icon.addClass("dim-label")
            widgets.append(UI.hbox(spacing: 8, [icon, text]))
        }
        var rows: [(String, String, Bool)] = []
        if let publisher = game.publisher { rows.append(("Publisher", publisher + (game.year.map { ", \($0)" } ?? ""), false)) }
        if let authors = game.authors { rows.append(("By", authors, false)) }
        rows.append(("Plays on", game.machine.summary, false))
        widgets.append(facts(rows))
        widgets.append(discList(game))
        widgets.append(web("View in the Archimedes Archive ↗", game.archivePageURL))
        widgets.append(UI.label("Disc images preserved by the Archimedes Archive and its contributors.", classes: ["caption", "dim-label"], wrap: true))
        fill(box, widgets)
    }

    private static func actions(for game: ClassicGame, parent: Widget) -> Widget {
        let classics = ClassicsLibrary.shared
        let box = UI.vbox(spacing: 8)
        switch classics.state(of: game) {
        case .notInstalled, .partial:
            UI.append(box, prominent("Get from the Archimedes Archive ↗") { classics.get(game) })
            UI.append(box, links([("Add Discs…", { classics.chooseAndImport(for: game, parent: parent) })]))
        case .waiting:
            UI.append(box, UI.label(game.discs.count > 1
                ? "Download the \(game.discs.count) files below from the Archimedes Archive. LinuxArch adds each as it finishes."
                : "Download \(game.discs[0].fileName) from the Archimedes Archive. LinuxArch adds it when it finishes.", wrap: true))
            if classics.autoDetect != true {
                UI.append(box, UI.label("Looking for downloads is off, so add the discs once they’re downloaded.",
                                        classes: ["caption", "dim-label"], wrap: true))
            }
            UI.append(box, prominent("Open the Archive Again ↗") { openURI(game.archivePageURL.absoluteString, parent: parent) })
            UI.append(box, spinner("Waiting for download…"))
            UI.append(box, links([("Add Discs…", { classics.chooseAndImport(for: game, parent: parent) }),
                                  ("Cancel Waiting", { classics.cancelWaiting(game) })]))
        case .importing:
            UI.append(box, spinner("Adding…"))
        case .installed:
            if classics.justInstalled == game.id {
                UI.append(box, UI.hbox(spacing: 6, [UI.image(icon: "object-select-symbolic"), UI.label("Added to your library")], classes: ["ready"]))
            }
            UI.append(box, prominent("Play", icon: "media-playback-start-symbolic") { Player.play(game) })
            UI.append(box, links([("Reveal Discs", { classics.reveal(game) }), ("Remove…", { classics.remove(game) })]))
        }
        return box
    }

    /// Its discs: which are in, each with a link to download it.
    private static func discList(_ game: ClassicGame) -> Widget {
        let classics = ClassicsLibrary.shared
        let box = UI.vbox(spacing: 6, [UI.label(game.discs.count == 1 ? "Disc" : "Discs", classes: ["heading"])])
        for disc in game.discs {
            let have = classics.has(disc, of: game)
            let icon = UI.image(icon: have ? "object-select-symbolic" : "content-loading-symbolic")
            icon.addClass(have ? "ready" : "dim-label")
            icon.align(vertical: GTK_ALIGN_START)
            let name: Widget
            if have {
                name = UI.label(disc.fileName, classes: ["caption", "dim-label"])
                gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_MIDDLE)
            } else {
                name = UI.button(disc.fileName + " ↗", classes: ["flat", "link-button", "caption"]) { classics.get(disc, of: game) }
                name.setTooltip("Download \(disc.fileName) from the Archimedes Archive")
                name.align(horizontal: GTK_ALIGN_START)
            }
            let text = UI.vbox(spacing: 1, [UI.label(disc.label), name])
            text.expand(horizontally: true)
            UI.append(box, UI.hbox(spacing: 6, [icon, text]))
        }
        return box
    }

    // MARK: The archive

    static func archive(_ archive: ClassicsArchive, into box: Widget, parent: Widget) {
        fill(box, [
            coverBox(Covers.archiveCover(archive, height: 260)),
            UI.label(archive.title, classes: ["title-2"], wrap: true),
            UI.label(archive.pitch, classes: ["heading"], wrap: true),
            prominent("Visit the Archimedes Archive ↗") { openURI(archive.url.absoluteString, parent: parent) },
            UI.label(branded(archive.about), wrap: true),
            UI.label("Disc images are downloaded from the Archimedes Archive in your browser. LinuxArch is an independent emulator and is not affiliated with the archive.",
                     classes: ["dim-label"], wrap: true),
        ])
    }

    // MARK: One of My Games

    static func personal(_ game: PersonalGame, into box: Widget, parent: Widget) {
        let library = GameLibrary.shared
        let cover = coverBox(Covers.cover(for: game, height: 260))
        acceptFileDrops(on: cover) { urls in library.attach(urls, to: game) }
        let byline = [game.publisher, game.year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
        var widgets = [cover, heading(game.title, (byline.isEmpty ? [] : [byline]) + ["My game"])]
        let actions = UI.vbox(spacing: 8)
        if game.discFile != nil {
            UI.append(actions, prominent("Play", icon: "media-playback-start-symbolic") { Player.play(game) })
        } else {
            UI.append(actions, UI.label("Add the game’s disc image to play it: drop it on the game, or choose it.", wrap: true))
            UI.append(actions, prominent("Choose Disc…") { library.chooseDisc(for: game, parent: parent) })
        }
        var edits: [(String, Handler)] = [("Edit…", { library.edit(game) })]
        if game.discFile != nil {
            edits.append(("Replace Disc…", { library.chooseDisc(for: game, parent: parent) }))
        }
        edits.append((game.coverFile == nil ? "Add Cover…" : "Change Cover…", { library.chooseCover(for: game, parent: parent) }))
        UI.append(actions, links(edits))
        var files: [(String, Handler)] = []
        if let url = library.myGames.discURL(game) {
            files.append(("Reveal Disc", { revealInFileManager(url, parent: parent) }))
        }
        files.append(("Remove…", { library.remove(game) }))
        UI.append(actions, links(files))
        widgets.append(actions)
        let start: (String, Bool) = switch game.start {
        case .boot: ("Running the disc’s !Boot", false)
        case .application(let name): ("Starting \(name)", false)
        case .insertOnly: ("Putting the disc in", false)
        case .type(let command): command.isEmpty ? ("Putting the disc in", false) : (command, true)
        }
        widgets.append(facts([("Plays on", game.machineSummary, false), ("Starts by", start.0, start.1)]))
        if let notes = game.notes {
            widgets.append(UI.label(notes, wrap: true, selectable: true))
        }
        fill(box, widgets)
    }
}

// MARK: Playing

/// Starts games in the Archimedes in front (or a new window's), asking
/// before taking over a machine that has a disc in.
@MainActor
enum Player {
    /// The machine to use, or nil (with `launch` saved for the new one's
    /// window, which is opened).
    private static func machine(or launch: @escaping (MachineController) -> Void) -> MachineController? {
        if let machine = MachineController.frontmost, machine.host != nil {
            return machine
        }
        MachineController.pendingLaunch = launch
        LinuxArchApp.shared.newWindow()
        return nil
    }

    static func play(_ game: PersonalGame) {
        guard let url = GameLibrary.shared.myGames.discURL(game) else { return }
        let launch: (MachineController) -> Void = { $0.play(game, disc: url) }
        guard let machine = machine(or: launch) else { return }
        Task {
            if let current = machine.discName, machine.playing != game.id {
                guard await Alerts.confirm("Play \(game.title)?",
                                           "The Archimedes starts \(game.title), replacing “\(current)”. Anything unsaved there is lost (Quick Save, Ctrl+Shift+F6, keeps it).",
                                           button: "Play", parent: frontWindow) else { return }
            }
            launch(machine)
            machine.window?.present()
        }
    }

    static func play(_ game: ClassicGame) {
        let classics = ClassicsLibrary.shared
        let floppies = classics.floppyURLs(game)
        let hardDisc = game.discs.contains { $0.kind == .hardDiscArchive } ? classics.store.hardDiscURL(game) : nil
        let cmos = classics.store.folder(game.id).appendingPathComponent("cmos.bin").path
        let launch: (MachineController) -> Void = { machine in
            Task { await machine.play(game, floppies: floppies, hardDisc: hardDisc, cmosPath: cmos) }
        }
        guard let machine = machine(or: launch) else { return }
        Task {
            if let current = machine.discName, machine.session?.gameID != game.id {
                guard await Alerts.confirm("Play \(game.title)?",
                                           "The Archimedes restarts as \(game.title) wants it, replacing “\(current)”. Anything unsaved there is lost (Quick Save, Ctrl+Shift+F6, keeps it).",
                                           button: "Play", parent: frontWindow) else { return }
            }
            await machine.play(game, floppies: floppies, hardDisc: hardDisc, cmosPath: cmos)
            machine.window?.present()
        }
    }
}

extension MachineController {
    /// Plays one of My Games: the machine it wants (power cycling if it's
    /// another), its disc in drive 0, then started as the game says.
    func play(_ game: PersonalGame, disc url: URL) {
        let rom = game.rom.flatMap { family in AppSettings.shared.romLibrary.first { $0.version.hasPrefix(family) }?.path }
        let changesMachine = game.model != model || (game.ramKB != nil && game.ramKB != ramKB) || (rom != nil && rom != romPath)
        if changesMachine {
            setHardware(model: game.model, ramKB: game.ramKB, romPath: rom)
        }
        guard let host else { return }
        do {
            let image = try FloppyImage.open(path: url.path)
            stopSessionDiscs()
            host.send { $0.machine.insertFloppy(image) }
            playing = game.id
            noteDisc(url)
        } catch {
            alert("Could not open \(game.title)’s disc", "\(error)")
            return
        }
        switch game.start {
        case .insertOnly:
            break
        case .boot:
            // The disc's !Boot, from the command line, as booting it would.
            atCommandLine("/ADFS::0.$.!Boot\n")
        case .application(let name):
            // Run, then an empty line back to the desktop, where it starts.
            atCommandLine("Run ADFS::0.$.\(name)\n\n")
        case .type(let command):
            guard !command.isEmpty else { break }
            atCommandLine(command.replacingOccurrences(of: ";", with: "\n") + "\n")
        }
    }

    /// Types at the desktop's command line (F12), once the machine's at its
    /// desktop (one that's just started takes a while).
    private func atCommandLine(_ text: String) {
        let f12: UInt8 = 0x0C
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                let up = self?.host?.sendAndWait { $0.machine.seconds } ?? 0
                if up > 25 { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self else { return }
            self.keyDown(f12)
            try? await Task.sleep(for: .milliseconds(150))
            self.keyUp(f12)
            try? await Task.sleep(for: .milliseconds(800))
            self.type(text)
        }
    }
}
