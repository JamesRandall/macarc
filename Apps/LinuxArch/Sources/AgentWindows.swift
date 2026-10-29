import MacArchAgent
import CGtk
import Foundation

/// How to point Claude Code and Codex at the MCP server in this copy of the
/// app, wherever it is.
@MainActor
final class MCPSetupWindow {
    private let window: Widget
    private let log = AgentLog.shared

    /// The command that runs the server: macarch-mcp beside the app, or in
    /// a Flatpak, the app's.
    private static var serverCommand: [String] {
        if let app = ProcessInfo.processInfo.environment["FLATPAK_ID"] {
            return ["flatpak", "run", "--command=macarch-mcp", app]
        }
        return [AppPaths.mcpServer.path]
    }

    private static func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:".contains($0) }
            ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var shellCommand: String {
        serverCommand.map(shellQuoted).joined(separator: " ")
    }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    init(app: OpaquePointer, onClose: @escaping Handler) {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), app.cast())
        gtk_window_set_title(window.cast(), "Connect an AI Agent")
        gtk_window_set_default_size(window.cast(), 640, 720)

        let page = adw_preferences_page_new()!

        let intro = group(nil, on: page)
        UI.append(intro, UI.label("Connect an AI agent to this LinuxArch, while it’s running, and it drives the Archimedes in the window as you watch: typing, using the mouse, loading discs, reading the screen, taking screenshots and debugging.", wrap: true))
        let second = UI.label("Add LinuxArch to your agent once with the command below. From then on, whenever LinuxArch is open, the agent attaches to it.", classes: ["dim-label"], wrap: true)
        second.setMargins(top: 8)
        UI.append(intro, second)
        let statusRow = adw_action_row_new()!
        adw_preferences_row_set_title(statusRow.cast(), "Status")
        let status = UI.label("")
        adw_action_row_add_suffix(statusRow.cast(), status)
        let statusList = gtk_list_box_new()!
        statusList.addClass("boxed-list")
        statusList.setMargins(top: 12)
        gtk_list_box_set_selection_mode(statusList.cast(), GTK_SELECTION_NONE)
        gtk_list_box_append(statusList.cast(), statusRow)
        UI.append(intro, statusList)

        let command = Self.serverCommand
        let claude = group("Claude Code", on: page)
        UI.append(claude, commandBlock("claude mcp add macarch -- \(Self.shellCommand) --attach"))
        UI.append(claude, note("Run this in a terminal, then start Claude Code in the same folder. Add --scope user after add to have it in every project."))

        let codex = group("Codex", on: page)
        UI.append(codex, commandBlock("codex mcp add macarch -- \(Self.shellCommand) --attach"))
        UI.append(codex, note("Run this in a terminal, then start Codex. Or add it to ~/.codex/config.toml yourself:"))
        let arguments = (command.dropFirst().map(Self.tomlString) + ["\"--attach\""]).joined(separator: ", ")
        UI.append(codex, commandBlock("[mcp_servers.macarch]\ncommand = \(Self.tomlString(command[0]))\nargs = [\(arguments)]"))

        let footer = group(nil, on: page)
        UI.append(footer, note("The commands use this copy of LinuxArch, where it is now: if you move it, add it again. The activity log (in the main menu’s AI Agents (MCP)) shows everything agents do here. (Without --attach, the server runs a hidden Archimedes of its own instead, using the ROM given with --rom or MACARCH_ROM.)"))
        if ProcessInfo.processInfo.environment["FLATPAK_ID"] == nil,
           !FileManager.default.isExecutableFile(atPath: AppPaths.mcpServer.path) {
            UI.append(footer, UI.label("The server isn’t at \(AppPaths.mcpServer.path).", classes: ["error-text"], wrap: true))
        }

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.cast(), page)
        adw_window_set_content(window.cast(), toolbar)

        let log = log
        observe(self) {
            let text: String = switch log.serverState {
            case .serving:
                switch log.connections {
                case 0: "Ready to attach, no agent connected"
                case 1: "An agent is connected"
                case let n: "\(n) agents are connected"
                }
            case .notStarted: "Not started"
            case .inUse: "Another copy of LinuxArch is serving agents"
            case .failed(let reason): "Not available: \(reason)"
            }
            UI.setText(status, text)
            status.setClass("warning", log.serverState != .serving)
            status.setClass("dim-label", log.serverState == .serving)
        }
        onSignalReturning(window, "close-request") {
            onClose()
            return false
        }
    }

    func present() {
        gtk_window_present(window.cast())
    }

    /// A preferences group on `page`, and the box its contents go in.
    private func group(_ title: String?, on page: Widget) -> Widget {
        let group = adw_preferences_group_new()!
        if let title { adw_preferences_group_set_title(group.cast(), title) }
        let box = UI.vbox(spacing: 8)
        adw_preferences_group_add(group.cast(), box)
        adw_preferences_page_add(page.cast(), group.cast())
        return box
    }

    private func note(_ text: String) -> Widget {
        UI.label(text, classes: ["dim-label"], wrap: true)
    }

    /// A command to copy.
    private func commandBlock(_ text: String) -> Widget {
        let label = UI.label(text, classes: ["code"], wrap: true, selectable: true)
        label.expand(horizontally: true)
        let copy = UI.button("Copy") {}
        copy.align(vertical: GTK_ALIGN_START)
        onSignal(copy, "clicked") {
            Clipboard.setText(text)
            gtk_button_set_label(copy.cast(), "Copied")
            after(1.5) { gtk_button_set_label(copy.cast(), "Copy") }
        }
        return UI.hbox(spacing: 8, [label, copy], classes: ["command-block"])
    }
}

/// What agents have done: each tool call, newest first, and the selected
/// one in full.
@MainActor
final class AgentLogWindow {
    private let window: Widget
    private let log = AgentLog.shared
    private let list: Widget
    private let detail: Widget
    private let stack: Widget
    private var shown: [UUID] = []
    private var rows: [UUID: Widget] = [:]
    private var selection: UUID?

    init(app: OpaquePointer, onClose: @escaping Handler) {
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), app.cast())
        gtk_window_set_title(window.cast(), "MCP Activity")
        gtk_window_set_default_size(window.cast(), 900, 560)

        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(list.cast(), GTK_SELECTION_SINGLE)
        list.addClass("rich-list")
        detail = UI.vbox(spacing: 8)
        detail.setMargins(12)

        let header = Self.row(time: "Time", tool: "Tool", arguments: "Arguments", result: "Result", took: "Took")
        header.addClass("heading")
        header.setMargins(top: 6, bottom: 6, start: 12, end: 12)
        let table = UI.vbox(spacing: 0, [header, UI.separator(), UI.scrolled(list, horizontal: GTK_POLICY_AUTOMATIC)])
        let paned = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(paned.cast(), table)
        gtk_paned_set_end_child(paned.cast(), UI.scrolled(detail))
        gtk_paned_set_position(paned.cast(), 300)

        let empty = adw_status_page_new()!
        adw_status_page_set_title(empty.cast(), "Nothing Yet")
        adw_status_page_set_icon_name(empty.cast(), "utilities-terminal-symbolic")
        adw_status_page_set_description(empty.cast(), "Tool calls from agents connected with macarch-mcp --attach appear here.")
        stack = gtk_stack_new()!
        gtk_stack_add_named(stack.cast(), paned, "log")
        gtk_stack_add_named(stack.cast(), empty, "empty")

        let headerBar = adw_header_bar_new()!
        let clear = UI.iconButton("user-trash-symbolic", tooltip: "Clear") { [weak self] in
            guard let self else { return }
            self.selection = nil
            self.log.clear()
        }
        adw_header_bar_pack_start(headerBar.cast(), clear)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), headerBar)
        adw_toolbar_view_set_content(toolbar.cast(), stack)
        adw_window_set_content(window.cast(), toolbar)

        onSignal(list, "selected-rows-changed") { [weak self] in
            guard let self else { return }
            let row = gtk_list_box_get_selected_row(self.list.cast())
            self.selection = row.flatMap { selected in self.rows.first { $0.value == selected.widget }?.key }
            self.showDetail()
        }
        observe(self) { [weak self] in
            guard let self else { return }
            self.update(self.log.entries)
            clear.setSensitive(!self.log.entries.isEmpty)
        }
        onSignalReturning(window, "close-request") {
            onClose()
            return false
        }
    }

    func present() {
        gtk_window_present(window.cast())
    }

    private static func row(time: String, tool: String, arguments: String, result: String, took: String,
                            isError: Bool = false, dim: Bool = false) -> Widget {
        func cell(_ text: String, width: Int32, mono: Bool = false, expand: Bool = false) -> Widget {
            let label = UI.label(text, classes: mono ? ["code-small"] : [])
            gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
            gtk_label_set_single_line_mode(label.cast(), 1)
            gtk_widget_set_size_request(label, width, -1)
            if expand { label.expand(horizontally: true) }
            if isError { label.addClass("error-text") }
            if dim { label.addClass("dim-label") }
            return label
        }
        return UI.hbox(spacing: 12, [
            cell(time, width: 100), cell(tool, width: 140), cell(arguments, width: 240, mono: true, expand: true),
            cell(result, width: 240, expand: true), cell(took, width: 70),
        ])
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func makeRow(_ entry: AgentLog.Entry) -> Widget {
        let time = Self.timeFormatter.string(from: entry.time)
        let content: Widget = switch entry.kind {
        case .call(let tool, let arguments, let result, let images, let isError, let duration):
            Self.row(time: time, tool: tool, arguments: arguments, result: Self.summary(result, images: images),
                     took: Self.format(duration), isError: isError)
        case .connected:
            Self.row(time: time, tool: "Agent connected", arguments: "", result: "", took: "", dim: true)
        case .disconnected:
            Self.row(time: time, tool: "Agent disconnected", arguments: "", result: "", took: "", dim: true)
        }
        content.setMargins(top: 4, bottom: 4, start: 12, end: 12)
        let row = gtk_list_box_row_new()!
        gtk_list_box_row_set_child(row.cast(), content)
        return row
    }

    /// Adds rows for new entries (at the top) and drops those gone.
    private func update(_ entries: [AgentLog.Entry]) {
        let ids = entries.map(\.id)
        let current = Set(ids)
        for id in shown where !current.contains(id) {
            if let row = rows.removeValue(forKey: id) {
                gtk_list_box_remove(list.cast(), row)
            }
        }
        let known = Set(shown)
        for entry in entries where !known.contains(entry.id) {
            let row = makeRow(entry)
            rows[entry.id] = row
            gtk_list_box_prepend(list.cast(), row)
        }
        shown = ids
        gtk_stack_set_visible_child_name(stack.cast(), entries.isEmpty ? "empty" : "log")
        if let selection, !current.contains(selection) {
            self.selection = nil
            showDetail()
        }
    }

    private func showDetail() {
        UI.removeAll(detail)
        guard let entry = log.entries.first(where: { $0.id == selection }),
              case .call(let tool, let arguments, let result, let images, let isError, let duration) = entry.kind else {
            UI.append(detail, UI.label("Select a call to see it in full.", classes: ["dim-label"]))
            return
        }
        UI.append(detail, UI.label("\(tool) — \(Self.format(duration))\(isError ? " — failed" : "")", classes: ["heading"]))
        if !arguments.isEmpty {
            UI.append(detail, UI.label(arguments, classes: ["code"], wrap: true, selectable: true))
        }
        UI.append(detail, UI.separator())
        if !result.isEmpty {
            UI.append(detail, UI.label(result, classes: ["code"], wrap: true, selectable: true))
        }
        for png in images {
            let bytes = png.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            defer { g_bytes_unref(bytes) }
            guard let texture = gdk_texture_new_from_bytes(bytes, nil) else { continue }
            let picture = gtk_picture_new_for_paintable(texture.opaque)!
            g_object_unref(texture.raw)
            gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_size_request(picture, 480, 376)
            picture.align(horizontal: GTK_ALIGN_START)
            UI.append(detail, picture)
        }
    }

    private static func summary(_ result: String, images: [Data]) -> String {
        let first = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        switch (first.isEmpty, images.count) {
        case (_, 0): return first
        case (true, let n): return n == 1 ? "Image" : "\(n) images"
        case (false, let n): return first + (n == 1 ? " + image" : " + \(n) images")
        }
    }

    private static func format(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }
}
