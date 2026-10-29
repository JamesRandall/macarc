import ArchimedesCore
import CGtk
import Foundation

// New Network, Share Over Internet and Join Econet Network. (The Mac app's.)

// MARK: New network

/// New Network: choose a template (or reopen a recent network).
@MainActor
final class NetworkStartWindow {
    private static var current: NetworkStartWindow?

    static func show() {
        if let current {
            gtk_window_present(current.window.cast())
            return
        }
        let start = NetworkStartWindow()
        current = start
        gtk_window_present(start.window.cast())
    }

    let window: Widget

    private init() {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_title(window.cast(), "New Network")
        gtk_window_set_default_size(window.cast(), 760, 620)

        let content = UI.vbox(spacing: 20)
        content.setMargins(28)
        UI.append(content, UI.vbox(spacing: 4, [
            UI.label("New Network", classes: ["title-1"]),
            UI.label("Archimedes that share an Econet, each running for real with Acorn’s own network software. Start from one of these, then add, arrange and use the machines.",
                     classes: ["dim-label"], wrap: true),
        ]))
        let cards = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(cards.cast(), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(cards.cast(), 1)
        gtk_flow_box_set_min_children_per_line(cards.cast(), 2)
        gtk_flow_box_set_max_children_per_line(cards.cast(), 3)
        gtk_flow_box_set_column_spacing(cards.cast(), 14)
        gtk_flow_box_set_row_spacing(cards.cast(), 14)
        for template in NetworkTemplate.allCases {
            let title = UI.label(template.title, classes: ["heading"])
            let summary = UI.label(template.summary, classes: ["dim-label"], wrap: true)
            let icon = UI.image(icon: Self.icon(template), size: 28)
            icon.addClass("accent")
            icon.align(horizontal: GTK_ALIGN_START)
            let card = UI.vbox(spacing: 10, [icon, title, summary])
            card.setMargins(6)
            let button = gtk_button_new()!
            gtk_button_set_child(button.cast(), card)
            button.addClass("template-card")
            gtk_widget_set_size_request(button, 200, 150)
            onSignal(button, "clicked") { [weak self] in self?.create(template) }
            gtk_flow_box_append(cards.cast(), button)
        }
        UI.append(content, cards)
        let recent = RecentNetworks.shared.existing
        if !recent.isEmpty {
            let list = UI.vbox(spacing: 2, [UI.label("Recent", classes: ["heading"])])
            for url in recent.prefix(5) {
                let button = UI.button(url.deletingPathExtension().lastPathComponent, classes: ["flat"]) { [weak self] in
                    NetworkStudioWindow.show(url)
                    self?.close()
                }
                button.setTooltip(url.path)
                gtk_widget_set_halign(gtk_button_get_child(button.cast())!, GTK_ALIGN_START)
                UI.append(list, button)
            }
            UI.append(content, list)
        }
        let open = UI.button("Open Network…") { [weak self] in
            guard let self else { return }
            NetworkStudioWindow.chooseAndOpen(parent: self.window)
            self.close()
        }
        let note = UI.label("New networks are saved in Documents ▸ LinuxArch Networks as you work.", classes: ["caption", "dim-label"], wrap: true)
        note.expand(horizontally: true)
        gtk_label_set_xalign(note.cast(), 1)
        UI.append(content, UI.hbox(spacing: 12, [open, note]))

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.cast(), UI.scrolled(content))
        adw_window_set_content(window.cast(), toolbar)
        onSignalReturning(window, "close-request") {
            Self.current = nil
            return false
        }
    }

    private static func icon(_ template: NetworkTemplate) -> String {
        switch template {
        case .twoArchimedes: "computer-symbolic"
        case .schoolClassroom: "network-workgroup-symbolic"
        case .family: "view-grid-symbolic"
        case .distributedMandelbrot: "applications-science-symbolic"
        case .empty: "list-add-symbolic"
        }
    }

    private func close() {
        gtk_window_close(window.cast())
    }

    private func create(_ template: NetworkTemplate) {
        let url = RecentNetworks.newURL(named: template.title)
        do {
            try NetworkPackage.create(template, at: url)
            NetworkStudioWindow.show(url)
            close()
        } catch {
            Alerts.show("Can’t make the network", Alerts.describe(error), parent: window)
        }
    }
}

// MARK: Sharing

/// Share Over Internet: put this network's machines in a private room others
/// join with a link or a code; then the room's invitation, who's in it, and
/// the host's controls. For a network that joined someone else's room, the
/// room and leaving it.
@MainActor
final class InternetShareDialog {
    private let session: NetworkSession
    private let parent: Widget
    private let dialog: Widget
    private let body: Widget
    private let onClose: Handler
    private var shared: Set<UUID>
    private var busy = false
    private var copied: String?

    init(session: NetworkSession, parent: Widget, onClose: @escaping Handler) {
        self.session = session
        self.parent = parent
        self.onClose = onClose
        shared = Set(session.project.internetRoom?.shared ?? session.project.stations.filter { $0.kind == .station }.map(\.id))
        dialog = adw_dialog_new()!.widget
        adw_dialog_set_title(dialog.cast(), "Internet Econet")
        adw_dialog_set_content_width(dialog.cast(), 560)
        adw_dialog_set_content_height(dialog.cast(), 640)
        body = UI.vbox(spacing: 16)
        body.setMargins(20)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.cast(), UI.scrolled(body))
        adw_dialog_set_child(dialog.cast(), toolbar)
        onSignal(dialog, "closed") { [weak self] in self?.onClose() }
        observe(widget: dialog) { [weak self] in
            guard let self else { return }
            // Shown again when the room changes (or it's shared or left).
            _ = (session.isInRoom, session.room, session.currentInvite, session.project.stations.map(\.stationNumber), session.showsScreens)
            after(0) { [weak self] in self?.rebuild() }
        }
    }

    func present() {
        adw_dialog_present(dialog.cast(), parent)
    }

    func close() {
        adw_dialog_close(dialog.cast())
    }

    private func error(_ text: String) {
        Alerts.show("Internet Econet", text, parent: dialog)
    }

    private func rebuild() {
        UI.removeAll(body)
        if session.isInRoom { inRoom() } else { setUp() }
    }

    // MARK: Before sharing

    private func setUp() {
        let session = session
        let icon = UI.image(icon: "network-workgroup-symbolic", size: 30)
        icon.addClass("teal")
        icon.align(vertical: GTK_ALIGN_START)
        let intro = UI.vbox(spacing: 2, [
            UI.label("Share Over the Internet", classes: ["title-2"]),
            UI.label("A private Econet network others join with a link or a code, from LinuxArch, MacArch or MacBeeb. Their Archimedes and BBC Micros appear on your network, and yours on theirs.",
                     classes: ["dim-label"], wrap: true),
        ])
        intro.expand(horizontally: true)
        UI.append(body, UI.hbox(spacing: 12, [icon, intro]))

        let name = adw_entry_row_new()!
        adw_preferences_row_set_title(name.cast(), "Network name")
        UI.setText(editable: name, session.project.name)
        let person = adw_entry_row_new()!
        adw_preferences_row_set_title(person.cast(), "Your name (shown to people who join)")
        UI.setText(editable: person, NetworkSession.roomDisplayName)
        let service = InternetEconetService.current
        let serviceRow = UI.actionRow("Service", suffixes: [UI.label(service.host ?? service.absoluteString, classes: ["dim-label"])])
        let form = gtk_list_box_new()!
        form.addClass("boxed-list")
        gtk_list_box_set_selection_mode(form.cast(), GTK_SELECTION_NONE)
        for row in [name, person, serviceRow] { gtk_list_box_append(form.cast(), row) }
        UI.append(body, form)
        UI.append(body, machineList())

        var allowScreens = false, showMine = false
        let mine = UI.check("Show my machines’ screens", active: false) { showMine = $0 }
        mine.setMargins(start: 20)
        mine.setSensitive(false)
        let screensNote = UI.label("", classes: ["caption", "dim-label"], wrap: true)
        let allow = UI.check("Let people share their machines’ screens", active: false) { on in
            allowScreens = on
            mine.setSensitive(on)
            if !on { UI.setActive(check: mine, false); showMine = false }
            UI.setText(screensNote, on
                ? "Screens go apart from Econet, a picture a second, and never get in its way. Nobody can type into your machines or reach anything else on your computer."
                : "Only Econet is shared: people who join can’t see your screens, type into your machines or reach anything else on your computer.")
        }
        allow.setTooltip("People in the network can choose to show their machines’ screens, live, on everyone’s canvas")
        UI.setText(screensNote, "Only Econet is shared: people who join can’t see your screens, type into your machines or reach anything else on your computer.")
        UI.append(body, UI.vbox(spacing: 6, [allow, mine, screensNote]))

        let create = UI.button("Create Private Network", classes: ["suggested-action"]) {}
        let cancel = UI.button("Cancel") { [weak self] in self?.close() }
        let update: Handler = { [weak self] in
            guard let self else { return }
            create.setSensitive(!self.busy && !UI.text(of: name).trimmingCharacters(in: .whitespaces).isEmpty && !self.shared.isEmpty)
        }
        onSignal(name, "changed", update)
        onSignal(create, "clicked") { [weak self] in
            guard let self else { return }
            self.busy = true
            update()
            NetworkSession.roomDisplayName = UI.text(of: person).trimmingCharacters(in: .whitespaces)
            let shared = self.shared
            Task {
                defer {
                    self.busy = false
                    update()
                }
                do {
                    try await session.share(on: service, name: UI.text(of: name).trimmingCharacters(in: .whitespaces), shared: shared,
                                            screenSharing: allowScreens, showsScreens: showMine)
                } catch {
                    self.error("Couldn’t create the network: \(error)")
                }
            }
        }
        update()
        UI.append(body, UI.hbox(spacing: 8, [UI.spacer(), cancel, create]))
    }

    private func machineList() -> Widget {
        let session = session
        let box = UI.vbox(spacing: 6, [UI.label("Machines to share", classes: ["heading"])])
        for node in session.project.stations {
            let warning = UI.label("People who join can log on to this file server and read and write whatever its accounts allow.",
                                   classes: ["caption", "warning"], wrap: true)
            warning.setMargins(start: 24)
            warning.setVisible(node.kind == .fileServer && shared.contains(node.id))
            let check = UI.check("\(node.stationNumber.map(String.init) ?? "–")  \(node.name)  \(node.setup?.model.displayName ?? "")",
                                 active: shared.contains(node.id)) { [weak self] on in
                guard let self else { return }
                if on { self.shared.insert(node.id) } else { self.shared.remove(node.id) }
                warning.setVisible(node.kind == .fileServer && on)
                if session.isInRoom { session.setShared(self.shared) }
            }
            UI.append(box, check)
            UI.append(box, warning)
        }
        return box
    }

    // MARK: Shared

    private func inRoom() {
        let session = session
        let link = session.project.internetRoom
        let room = session.room
        let hosting = link?.hosting == true
        let people = room?.participants.count ?? 0
        let title = UI.vbox(spacing: 2, [
            UI.label(room?.room?.name ?? link?.roomName ?? "", classes: ["title-2"]),
            UI.label("Private · \(people) \(people == 1 ? "person" : "people") · \(link?.service.host ?? "")", classes: ["dim-label"]),
        ])
        title.expand(horizontally: true)
        UI.append(body, UI.hbox(spacing: 8, [title, Self.connectionBadge(room?.state)]))
        if let problem = room?.problem, room?.state != .connected {
            UI.append(body, UI.label(problem, classes: ["warning"], wrap: true))
        }
        if case .ended(let reason) = room?.state {
            UI.append(body, UI.label(reason, classes: ["error-text"], wrap: true))
        }
        if hosting { UI.append(body, invitation()) }
        UI.append(body, participants())
        if let conflicts = conflictsView() { UI.append(body, conflicts) }

        let allowed = room?.room?.allowsScreens == true
        var screens: [Widget] = []
        if hosting {
            screens.append(UI.check("Let people share their machines’ screens", active: allowed) { [weak self] on in
                Task {
                    do { try await session.setScreenSharingAllowed(on) } catch { self?.error("\(error)") }
                }
            })
        }
        let mine = UI.check("Show my machines’ screens", active: session.showsScreens) { on in session.setShowsScreens(on) }
        mine.setSensitive(allowed)
        mine.setTooltip(allowed ? "Everyone in the network sees your shared machines’ screens, live, on their canvas"
                        : "The network’s host hasn’t allowed screen sharing")
        screens.append(mine)
        UI.append(body, UI.vbox(spacing: 6, screens))

        let machines = gtk_expander_new("Machines shared")!
        gtk_expander_set_child(machines.cast(), machineList())
        UI.append(body, machines)

        var buttons: [Widget] = []
        if hosting {
            buttons.append(UI.check("Let new people join", active: room?.room?.locked != true) { open in
                Task { try? await session.setRoomLocked(!open) }
            })
        }
        buttons.append(UI.spacer())
        let stop = UI.button(hosting ? "Stop Sharing…" : "Leave Network…", classes: ["destructive-action"]) { [weak self] in
            Task {
                guard await Alerts.confirm(hosting ? "Stop sharing this network?" : "Leave this network?",
                                           hosting ? "The network closes for everyone in it: their machines disappear from yours, and yours from theirs. Its link and code stop working."
                                           : "Your machines leave the network, and its machines disappear from yours.",
                                           button: hosting ? "Stop Sharing" : "Leave", destructive: true, parent: self?.dialog) else { return }
                await session.leaveRoom()
            }
        }
        buttons.append(stop)
        buttons.append(UI.button("Done", classes: ["suggested-action"]) { [weak self] in self?.close() })
        UI.append(body, UI.hbox(spacing: 8, buttons))
    }

    static func connectionBadge(_ state: RoomConnection.State?) -> Widget {
        let (text, colour): (String, String) = switch state {
        case .connected: ("Connected", "ready")
        case .connecting, nil: ("Connecting…", "waiting")
        case .reconnecting: ("Reconnecting…", "waiting")
        case .ended: ("Disconnected", "error-text")
        case .stopped: ("Not connected", "dim-label")
        }
        return UI.label("● " + text, classes: [colour])
    }

    private func invitation() -> Widget {
        let session = session
        let box = UI.vbox(spacing: 10, classes: ["banner-card"])
        if let invite = session.currentInvite {
            func line(_ label: String, _ value: String, classes: [String], copyLabel: String) -> Widget {
                let name = UI.label(label, classes: ["dim-label"])
                gtk_widget_set_size_request(name, 90, -1)
                let text = UI.label(value, classes: classes, selectable: true)
                gtk_label_set_ellipsize(text.cast(), PANGO_ELLIPSIZE_MIDDLE)
                text.expand(horizontally: true)
                let copy = UI.button(copied == value ? "Copied" : copyLabel) {}
                onSignal(copy, "clicked") { [weak self] in
                    Clipboard.setText(value)
                    self?.copied = value
                    gtk_button_set_label(copy.cast(), "Copied")
                }
                return UI.hbox(spacing: 8, [name, text, copy])
            }
            UI.append(box, line("Join code", invite.code, classes: ["code", "title-4"], copyLabel: "Copy Code"))
            UI.append(box, line("Invite link", invite.url, classes: [], copyLabel: "Copy Link"))
            let note = UI.label("Works for 24 hours, for up to \(invite.maxUses) people.", classes: ["caption", "dim-label"])
            note.expand(horizontally: true)
            let withdraw = UI.button("Withdraw") { Task { try? await session.withdrawInvitation() } }
            withdraw.setTooltip("The link and code stop working; anyone already in stays")
            UI.append(box, UI.hbox(spacing: 8, [note, withdraw, UI.button("New Invitation") { Task { try? await session.newInvitation() } }]))
        } else {
            let text = UI.label("Make an invitation to let someone join: a link to send, or a code to read out.", classes: ["dim-label"], wrap: true)
            text.expand(horizontally: true)
            UI.append(box, UI.hbox(spacing: 8, [text, UI.button("New Invitation") { [weak self] in
                Task {
                    do { try await session.newInvitation() } catch { self?.error("\(error)") }
                }
            }]))
        }
        return box
    }

    private func participants() -> Widget {
        let session = session
        let room = session.room
        let box = UI.vbox(spacing: 6, [UI.label("In the network", classes: ["heading"])])
        for person in room?.participants ?? [] {
            let isMe = person.id == room?.participantId
            let stations = (room?.stations ?? []).filter { $0.participantId == person.id }
            let dot = UI.label("●", classes: [person.online ? "ready" : "dim-label"])
            dot.align(vertical: GTK_ALIGN_START)
            let text = UI.vbox(spacing: 2, [
                UI.label(person.name + (isMe ? " (you)" : "") + (person.owner ? " · host" : "")),
                UI.label(stations.isEmpty ? "No machines" : stations.map { "\($0.station) \($0.label)" }.joined(separator: ", "),
                         classes: ["caption", "dim-label"], wrap: true),
            ])
            text.expand(horizontally: true)
            var row = [dot, text]
            if let rtt = person.rttMs, person.online { row.append(UI.label("\(rtt) ms", classes: ["caption", "dim-label", "numeric"])) }
            if session.project.internetRoom?.hosting == true && !isMe {
                row.append(UI.button("Remove", classes: ["flat"]) { Task { try? await session.removeFromRoom(person.id) } })
            }
            UI.append(box, UI.hbox(spacing: 8, row))
        }
        return box
    }

    /// Machines whose station numbers someone else in the room already has,
    /// each with a number to change to: the change (and the restart it
    /// needs, for a machine that's on) only when asked.
    private func conflictsView() -> Widget? {
        let session = session
        let conflicts = session.roomConflicts
        guard !conflicts.isEmpty else { return nil }
        let box = UI.vbox(spacing: 8, classes: ["warning-card"])
        for conflict in conflicts {
            let text = UI.label("Someone in the network already has station \(conflict.station), so \(conflict.name) isn’t in it.", wrap: true)
            text.expand(horizontally: true)
            var row = [UI.image(icon: "dialog-warning-symbolic"), text]
            if let number = conflict.suggestion {
                let change = UI.button("Change to \(number)…") { [weak self] in
                    Task {
                        guard await Alerts.confirm("Change \(conflict.name) to station \(number)?",
                                                   conflict.isOn ? "Its network interface takes its number when it starts, so it starts again: what’s in its memory is lost. Its discs stay in their drives."
                                                   : "It takes the new number when it’s switched on.",
                                                   button: conflict.isOn ? "Change and Restart" : "Change", parent: self?.dialog) else { return }
                        if let problem = session.renumberForRoom(conflict.node, to: number) { self?.error(problem) }
                    }
                }
                change.setTooltip("Give \(conflict.name) station number \(number), which nobody in the network has")
                row.append(change)
            }
            UI.append(box, UI.hbox(spacing: 10, row))
        }
        return box
    }
}

// MARK: Joining

/// Invitation links (macarch://join…) waiting for the Join window.
@MainActor
final class JoinRequests {
    static let shared = JoinRequests()
    private var pending: URL?

    func handle(_ url: URL) {
        pending = url
        JoinRoomWindow.show()
    }

    func take() -> URL? {
        defer { pending = nil }
        return pending
    }

    static func isJoinLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "macarch" && url.host?.lowercased() == "join"
    }
}

/// Join Econet Network: a code someone read out, or an invitation link, to
/// the room it's for; then which network joins it. Also opened by
/// macarch://join links from an invitation's web page.
@MainActor
final class JoinRoomWindow {
    private static var current: JoinRoomWindow?

    static func show() {
        if let current {
            current.takePending()
            gtk_window_present(current.window.cast())
            return
        }
        let join = JoinRoomWindow()
        current = join
        gtk_window_present(join.window.cast())
        join.takePending()
    }

    enum Target: Equatable {
        case newA3000
        case newA5000
        case network(URL)
    }

    /// What was typed or pasted, read: a code (for the service in use), or
    /// a link (which names its own service).
    private struct Invitation: Equatable {
        var service: URL
        var code: String?
        var token: String?
    }

    let window: Widget
    private let entry: Widget
    private let lookUpButton: Widget
    private let joinButton: Widget
    private let status: Widget
    private let previewBox: Widget
    private var preview: InvitePreview?
    private var lookingUp = false
    private var joining = false
    private var target = Target.newA3000
    private var displayName = NetworkSession.roomDisplayName
    private var makeDefault = false
    private var showScreen = false

    private init() {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_title(window.cast(), "Join Econet Network")
        gtk_window_set_default_size(window.cast(), 600, 560)
        entry = UI.entry(placeholder: "ACRN-XXXX-XXXX-XXXX or a link")
        entry.addClass("code")
        entry.expand(horizontally: true)
        lookUpButton = UI.button("Look Up") {}
        joinButton = UI.button("Join", classes: ["suggested-action"]) {}
        status = UI.vbox(spacing: 6)
        previewBox = UI.vbox(spacing: 12)
        let icon = UI.image(icon: "network-workgroup-symbolic", size: 30)
        icon.addClass("teal")
        let intro = UI.vbox(spacing: 2, [
            UI.label("Join an Econet Network", classes: ["title-2"]),
            UI.label("Enter the code you were given, or paste the invitation link.", classes: ["dim-label"]),
        ])
        let cancel = UI.button("Cancel") { [weak self] in self.map { gtk_window_close($0.window.cast()) } }
        let content = UI.vbox(spacing: 16, [UI.hbox(spacing: 12, [icon, intro]), UI.hbox(spacing: 8, [entry, lookUpButton]), status, previewBox,
                                            UI.hbox(spacing: 8, [UI.spacer(), cancel, joinButton])])
        content.setMargins(20)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.cast(), UI.scrolled(content))
        adw_window_set_content(window.cast(), toolbar)
        onSignal(entry, "activate") { [weak self] in self?.lookUp() }
        onSignal(entry, "changed") { [weak self] in
            self?.preview = nil
            self?.showState(error: nil)
        }
        onSignal(lookUpButton, "clicked") { [weak self] in self?.lookUp() }
        onSignal(joinButton, "clicked") { [weak self] in self?.join() }
        onSignalReturning(window, "close-request") {
            Self.current = nil
            return false
        }
        showState(error: nil)
    }

    private func takePending() {
        if let pending = JoinRequests.shared.take() {
            UI.setText(editable: entry, pending.absoluteString)
            lookUp()
        }
    }

    private var typed: String { UI.text(of: entry) }

    private var invitation: Invitation? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "macarch" || scheme == "macbeeb", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let service = items.first(where: { $0.name == "service" })?.value.flatMap({ try? InternetEconetService.validate($0).get() }),
               let token = items.first(where: { $0.name == "invite" })?.value {
                return Invitation(service: service, token: token)
            }
            if scheme == "https" || scheme == "http", url.path.hasPrefix("/join/"),
               let origin = try? InternetEconetService.validate("\(scheme)://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")").get() {
                return Invitation(service: origin, token: String(url.path.dropFirst("/join/".count)))
            }
        }
        return Invitation(service: InternetEconetService.current, code: text)
    }

    /// An invitation to another service than the one set.
    private var otherService: URL? {
        guard let invitation, InternetEconetService.origin(invitation.service) != InternetEconetService.origin(InternetEconetService.current) else { return nil }
        return invitation.service
    }

    private func showState(error: String?) {
        UI.removeAll(status)
        if let otherService {
            UI.append(status, UI.label("This invitation is for \(otherService.host ?? otherService.absoluteString), not the service you use (\(InternetEconetService.current.host ?? "")). Only join if you trust whoever sent it.",
                                       classes: ["warning"], wrap: true))
        }
        if lookingUp {
            let spinner = adw_spinner_new()!
            gtk_widget_set_size_request(spinner, 16, 16)
            spinner.align(horizontal: GTK_ALIGN_START)
            UI.append(status, spinner)
        }
        if let error {
            UI.append(status, UI.label(error, classes: ["error-text"], wrap: true))
            if invitation?.code != nil && !InternetEconetService.isOfficial || error.contains("different") {
                let settings = UI.button("Internet Econet Service Preferences…", classes: ["flat"]) { [weak self] in
                    PreferencesDialog.present(parent: self?.window, page: .networking)
                }
                settings.align(horizontal: GTK_ALIGN_START)
                UI.append(status, settings)
            }
        }
        lookUpButton.setSensitive(invitation != nil && !lookingUp)
        joinButton.setSensitive(preview != nil && !joining)
        showPreview()
    }

    private func showPreview() {
        UI.removeAll(previewBox)
        guard let preview else { return }
        previewBox.addClass("banner-card")
        var header = [UI.label(preview.room.name, classes: ["title-3"])]
        if !preview.room.description.isEmpty { header.append(UI.label(preview.room.description, classes: ["dim-label"], wrap: true)) }
        header.append(UI.label("\(preview.participants) \(preview.participants == 1 ? "person" : "people") · on \(invitation?.service.host ?? "")",
                               classes: ["dim-label"]))
        UI.append(previewBox, UI.vbox(spacing: 4, header))
        if !preview.stations.isEmpty {
            let stations = UI.vbox(spacing: 3)
            for station in preview.stations {
                UI.append(stations, UI.hbox(spacing: 6, [UI.label("\(station.station)", classes: ["station-badge", "small"], xalign: 0.5),
                                                          UI.label(station.label), UI.label(station.kind, classes: ["dim-label"])]))
            }
            UI.append(previewBox, stations)
        }
        UI.append(previewBox, UI.separator())
        let open = NetworkSession.open.values.filter { !$0.isInRoom }.sorted { $0.project.name < $1.project.name }
        let targets: [Target] = [.newA3000, .newA5000] + open.map { .network($0.url) }
        let names = ["A new network with an A3000", "A new network with an A5000"] + open.map { "“\($0.project.name)”, open now" }
        let clashes = UI.label("", classes: ["warning"], wrap: true)
        func showClashes() {
            guard case .network(let url) = target, let session = NetworkSession.opened(url) else {
                clashes.setVisible(false)
                return
            }
            let taken = Set(preview.stations.map(\.station))
            let clashing = session.project.stations.filter { $0.stationNumber.map(taken.contains) ?? false }
            UI.setText(clashes, clashing.map { "\($0.name) (\($0.stationNumber ?? 0))" }.joined(separator: ", ")
                       + ": someone in the network has that station number already. Once you’ve joined, LinuxArch offers a free one.")
            clashes.setVisible(!clashing.isEmpty)
        }
        let picker = UI.dropDown(names, selected: targets.firstIndex(of: target) ?? 0) { [weak self] index in
            self?.target = targets[index]
            showClashes()
        }
        let label = UI.label("Join with", classes: ["dim-label"])
        picker.expand(horizontally: true)
        UI.append(previewBox, UI.hbox(spacing: 8, [label, picker]))
        showClashes()
        UI.append(previewBox, clashes)
        let name = UI.entry(placeholder: "Your name (shown to the others)")
        UI.setText(editable: name, displayName)
        onSignal(name, "changed") { [weak self] in self?.displayName = UI.text(of: name) }
        UI.append(previewBox, name)
        if preview.room.allowsScreens {
            let screen = UI.check("Show my machine’s screen to the others", active: showScreen) { [weak self] on in self?.showScreen = on }
            screen.setTooltip("This network lets people share their screens: yours appears, live, on their canvas. You can change your mind later.")
            UI.append(previewBox, screen)
        }
        if let otherService {
            UI.append(previewBox, UI.check("Use \(otherService.host ?? "") for my own networks too", active: makeDefault) { [weak self] on in
                self?.makeDefault = on
            })
        }
        UI.append(previewBox, UI.label("Your machines’ Econet joins the network; nothing else on your computer is shared.",
                                       classes: ["caption", "dim-label"], wrap: true))
    }

    private func lookUp() {
        guard let invitation, !lookingUp else { return }
        lookingUp = true
        showState(error: nil)
        Task {
            var problem: String?
            do {
                let api = RoomAPI(service: invitation.service)
                let info = try await api.serviceInfo()
                if let incompatibility = info.incompatibility {
                    problem = "\(invitation.service.host ?? ""): \(incompatibility)."
                } else {
                    preview = try await api.resolve(code: invitation.code, token: invitation.token)
                }
            } catch let error as RoomAPIError {
                problem = error.message
            } catch {
                problem = "Couldn’t reach \(invitation.service.host ?? "the service"). Check the Internet connection, and the address."
            }
            lookingUp = false
            showState(error: problem)
        }
    }

    private func join() {
        guard let invitation, let preview else { return }
        joining = true
        showState(error: nil)
        NetworkSession.roomDisplayName = displayName.trimmingCharacters(in: .whitespaces)
        let target = target, showScreen = showScreen, makeDefault = makeDefault, displayName = displayName
        Task {
            var problem: String?
            do {
                let api = RoomAPI(service: invitation.service)
                let joined = try await api.join(roomId: preview.roomId, code: invitation.code, token: invitation.token,
                                                displayName: displayName.isEmpty ? "Guest" : displayName)
                let session: NetworkSession
                switch target {
                case .network(let url):
                    session = try NetworkSession.session(for: url)
                case .newA3000, .newA5000:
                    session = try Self.makeNetwork(for: preview, model: target == .newA5000 ? .a5000 : .a3000)
                }
                try session.enterRoom(service: invitation.service, roomId: preview.roomId, roomName: preview.room.name,
                                      joined: joined, shared: Set(session.project.stations.map(\.id)),
                                      showsScreens: showScreen && preview.room.allowsScreens)
                if makeDefault { InternetEconetService.current = invitation.service }
                NetworkStudioWindow.show(session.url)
                gtk_window_close(window.cast())
            } catch let error as RoomAPIError {
                problem = error.message
            } catch {
                problem = "Couldn’t join: \(error)"
            }
            joining = false
            if let problem { showState(error: problem) }
        }
    }

    /// A network of its own for the room: one machine, at a station number
    /// nobody in the room has, and a clock.
    private static func makeNetwork(for preview: InvitePreview, model: MachineModel) throws -> NetworkSession {
        let taken = Set(preview.stations.map(\.station))
        let number = (1...253).first { !taken.contains($0) && $0 != 235 } ?? 1
        var project = NetworkProject(name: preview.room.name)
        project.nodes = [
            NetworkNode(kind: .station, name: "\(model.rawValue) \(number)", stationNumber: number, setup: StationSetup(model: model),
                        position: CanvasPoint(x: 0, y: 0)),
            .clock(at: CanvasPoint(x: 0, y: NetworkProject.rowSpacing)),
        ]
        project.workspace.tiles = project.stations.map(\.id)
        let url = RecentNetworks.newURL(named: preview.room.name)
        try NetworkPackage.save(project, to: url)
        return try NetworkSession.session(for: url)
    }
}
