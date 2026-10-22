import AppKit
import SwiftUI

/// MCP > Connect an AI Agent…: the commands that add this copy of MacArch
/// to Claude Code or Codex.
struct MCPSetupView: View {
    @State private var log = AgentLog.shared

    static var serverURL: URL {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macarch-mcp")
    }

    static var shellPath: String { "'" + serverURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static var tomlPath: String { "\"" + serverURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    var body: some View {
        Form {
            Section {
                Text("Connect an AI agent to this MacArch, while it's running, and it drives the Archimedes in the window as you watch: typing, using the mouse, loading discs, reading the screen, taking screenshots and debugging.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Add MacArch to your agent once with the command below. From then on, whenever MacArch is open, the agent attaches to it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Status") {
                    Text(status).foregroundStyle(log.serverState == .serving ? Color.secondary : Color.orange)
                }
            }
            Section("Claude Code") {
                CommandBlock(text: "claude mcp add macarch -- \(Self.shellPath) --attach")
                Text("Run this in a terminal, then start Claude Code in the same folder. Add `--scope user` after `add` to have it in every project.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Codex") {
                CommandBlock(text: "codex mcp add macarch -- \(Self.shellPath) --attach")
                Text("Run this in a terminal, then start Codex. Or add it to ~/.codex/config.toml yourself:")
                    .font(.callout).foregroundStyle(.secondary)
                CommandBlock(text: "[mcp_servers.macarch]\ncommand = \(Self.tomlPath)\nargs = [\"--attach\"]")
            }
            Section {
                Text("The commands use this copy of MacArch, where it is now: if you move the app, add it again. MCP > Activity Log shows everything agents do here. (Without `--attach`, the server runs a hidden Archimedes of its own instead, using the ROM you chose here.)")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !FileManager.default.isExecutableFile(atPath: Self.serverURL.path) {
                    Text("The server isn't at \(Self.serverURL.path).").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String {
        switch log.serverState {
        case .serving:
            switch log.connections {
            case 0: return "Ready to attach, no agent connected"
            case 1: return "An agent is connected"
            case let n: return "\(n) agents are connected"
            }
        case .notStarted: return "Not started"
        case .inUse: return "Another copy of MacArch is serving agents"
        case .failed(let reason): return "Not available: \(reason)"
        }
    }
}

struct CommandBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
        }
    }
}

/// MCP > Activity Log: every tool call agents make, newest first.
struct AgentLogView: View {
    @State private var log = AgentLog.shared
    @State private var selection: AgentLog.Entry.ID?

    var body: some View {
        VSplitView {
            Table(log.entries.reversed(), selection: $selection) {
                TableColumn("Time") { e in
                    Text(e.time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))).monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn("Tool") { e in
                    switch e.kind {
                    case .call(let tool, _, _, _, let isError, _): Text(tool).foregroundStyle(isError ? Color.red : Color.primary)
                    case .connected: Text("Agent connected").foregroundStyle(.secondary)
                    case .disconnected: Text("Agent disconnected").foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Arguments") { e in
                    if case .call(_, let args, _, _, _, _) = e.kind { Text(args).font(.system(.body, design: .monospaced)).lineLimit(1) }
                }
                .width(min: 120, ideal: 260)
                TableColumn("Result") { e in
                    if case .call(_, _, let result, let images, let isError, _) = e.kind {
                        Text(resultLine(result, images.count)).foregroundStyle(isError ? Color.red : Color.primary).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 260)
                TableColumn("Took") { e in
                    if case .call(_, _, _, _, _, let d) = e.kind { Text(took(d)).monospacedDigit().foregroundStyle(.secondary) }
                }
                .width(min: 50, ideal: 70)
            }
            .frame(minHeight: 150)
            .overlay {
                if log.entries.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "text.badge.checkmark",
                                           description: Text("Tool calls from agents connected with macarch-mcp --attach appear here."))
                }
            }
            detail.frame(minHeight: 120)
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar {
            Button { log.clear(); selection = nil } label: { Label("Clear", systemImage: "trash") }
                .disabled(log.entries.isEmpty)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let e = log.entries.first(where: { $0.id == id }), case .call(let tool, let args, let result, let images, let isError, let d) = e.kind {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(tool) — \(took(d))" + (isError ? " — failed" : "")).font(.headline)
                    Text(args).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Divider()
                    Text(result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                        if let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit).frame(maxWidth: 480)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            Text("Select a call to see it in full.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultLine(_ text: String, _ images: Int) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let pics = images == 0 ? "" : images == 1 ? "image" : "\(images) images"
        if first.isEmpty { return pics.capitalized }
        return first + (pics.isEmpty ? "" : " + " + pics)
    }

    private func took(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s < 1 ? "\(Int(s * 1000)) ms" : String(format: "%.2f s", s)
    }
}

/// The toolbar's MCP light: an agent is attached (it glows while a call runs).
struct AgentLight: View {
    @State private var log = AgentLog.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if log.connections > 0 {
            Button { openWindow(id: "mcp-log") } label: {
                VStack(spacing: 2) {
                    Circle()
                        .fill(Color.green)
                        .opacity(log.callsRunning > 0 ? 1 : 0.6)
                        .shadow(color: log.callsRunning > 0 ? .green : .clear, radius: 4)
                        .frame(width: 7, height: 7)
                        .phaseAnimator([1.0, 0.45]) { content, phase in content.opacity(log.callsRunning > 0 ? phase : 1) }
                    Text("MCP").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(log.connections == 1 ? "An AI agent is attached (click for the activity log)" : "\(log.connections) AI agents are attached (click for the activity log)")
            .accessibilityLabel(log.callsRunning > 0 ? "AI agent attached, working" : "AI agent attached")
        }
    }
}
