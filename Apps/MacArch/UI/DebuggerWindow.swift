import AppKit
import ArchimedesCore
import SwiftUI

/// The debugger window (after MacBeeb's): disassembly and memory on the
/// left, the CPU, breakpoints, hardware, trace, profile and log on the right.
struct DebuggerWindow: View {
    @State var model: DebuggerModel

    var body: some View {
        HSplitView {
            if model.view.basic {
                VSplitView {
                    BasicListingView(model: model).frame(minHeight: 220, idealHeight: 440)
                    BasicVariablesView(model: model).frame(minHeight: 160, idealHeight: 280)
                }
                .frame(minWidth: 560, idealWidth: 680)
                BasicSidebar(model: model).frame(minWidth: 320, idealWidth: 380)
            } else {
                VSplitView {
                    DisassemblyView(model: model).frame(minHeight: 220, idealHeight: 420)
                    MemoryView(model: model).frame(minHeight: 180, idealHeight: 300)
                }
                .frame(minWidth: 560, idealWidth: 680)
                DebuggerSidebar(model: model).frame(minWidth: 320, idealWidth: 380)
            }
        }
        .toolbar { DebuggerToolbar(model: model) }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct DebuggerToolbar: ToolbarContent {
    @Bindable var model: DebuggerModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $model.view.basic) {
                Text("Machine Code").tag(false)
                Text("BASIC").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Debug machine code, or a BASIC program by its lines")
        }
        if model.view.basic {
            basicItems
        } else {
            machineCodeItems
        }
        ToolbarItem(placement: .status) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var f6: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)) }
    private var f7: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)) }
    private var f8: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)) }

    @ToolbarContentBuilder private var basicItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.basicPauseOrContinue() } label: {
                Label(model.isStopped ? "Continue" : "Pause", systemImage: model.isStopped ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("y", modifiers: [.command, .control])
            .help(model.isStopped ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y): at the next BASIC statement")
            Button { model.basicStep(.over) } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                .keyboardShortcut(f6, modifiers: [])
                .help("Step over (F6): to the next statement, running PROCs, FNs and GOSUBs through")
                .disabled(!model.isStopped)
            Button { model.basicStep(.into) } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                .keyboardShortcut(f7, modifiers: [])
                .help("Step into (F7): to the next statement, into PROCs, FNs and GOSUBs")
                .disabled(!model.isStopped)
            Button { model.basicStep(.out) } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                .keyboardShortcut(f8, modifiers: [])
                .help("Step out (F8): until this PROC, FN or subroutine returns")
                .disabled(!model.isStopped)
        }
    }

    private var statusText: String {
        guard let s = model.snapshot else { return "" }
        if let reason = s.stopReason { return "Stopped: \(reason)" }
        if s.isRunningCommand && s.view.basic { return "Running to a BASIC statement…" }
        return s.isRunningCommand ? "Stepping…" : "Running"
    }

    @ToolbarContentBuilder private var machineCodeItems: some ToolbarContent {
        ToolbarItemGroup {
            let stopped = model.isStopped
            Button { model.pauseOrContinue() } label: {
                Label(stopped ? "Continue" : "Pause", systemImage: stopped ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("y", modifiers: [.command, .control])
            .help(stopped ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y)")
            Button { model.run(.stepOver) } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                .help("Step over (F6): a BL or SWI runs to the next instruction")
                .disabled(!stopped)
            Button { model.run(.stepInstruction) } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [])
                .help("Step into (F7): one instruction")
                .disabled(!stopped)
            Button { model.run(.stepOut) } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                .help("Step out (F8): until this routine returns to R14, or the interrupt handler ends")
                .disabled(!stopped)
            Button { model.stepBack() } label: { Label("Step Back", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [.shift])
                .help("Step back (⇧F7): to the previous instruction, from the rewind history")
                .disabled(!stopped)
            Button { model.reverseContinue() } label: { Label("Reverse Continue", systemImage: "backward.end.fill") }
                .keyboardShortcut("y", modifiers: [.command, .control, .shift])
                .help("Reverse continue (⇧⌃⌘Y): back to the last breakpoint hit")
                .disabled(!stopped)
            Menu {
                Button("Next Scanline") { model.run(.nextScanline) }
                Button("Next Frame") { model.run(.nextFrame) }
                Button("Next Interrupt") { model.run(.nextInterrupt) }
            } label: {
                Label("Step By", systemImage: "forward.frame")
            }
            .help("Step to the next scanline, frame or interrupt")
        }
    }
}

// MARK: Disassembly

struct DisassemblyView: View {
    let model: DebuggerModel
    @State private var goTo = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disassembly").font(.headline)
                Spacer()
                TextField("Go to address", text: $goTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit {
                        if let a = model.address(goTo) { model.view.disassemblyStart = a & ~3 } else { model.message = "Bad address: \(goTo)" }
                    }
                Button("PC") { model.view.disassemblyStart = nil }.help("Follow the program counter")
                Button { loadSymbols() } label: { Image(systemName: "tag") }.help("Load symbols: a label file (name = &8000, nm output…)")
                Button { scroll(by: -48) } label: { Image(systemName: "chevron.up") }.help("Earlier")
                Button { scroll(by: 24) } label: { Image(systemName: "chevron.down") }.help("Later")
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.snapshot?.disassembly ?? []) { line in row(line) }
                }
            }
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.red).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func scroll(by lines: Int) {
        let start = model.snapshot?.disassembly.first?.address ?? 0
        model.view.disassemblyStart = start &+ UInt32(bitPattern: Int32(lines * 4))
    }

    private func loadSymbols() {
        let p = NSOpenPanel()
        p.message = "Choose a label file (name = &8000, name EQU &8000, or nm output)"
        if p.runModal() == .OK, let url = p.url { model.loadSymbols(url) }
    }

    @ViewBuilder private func row(_ line: DebugSnapshot.Line) -> some View {
        let stopped = model.isStopped
        VStack(alignment: .leading, spacing: 0) {
            ForEach(line.labels, id: \.self) { Text("\($0):").foregroundStyle(.tint).padding(.leading, 44) }
            HStack(spacing: 6) {
                Button { model.toggleBreakpoint(at: line.address) } label: {
                    Circle()
                        .fill(line.breakpoints.isEmpty ? Color.clear : Color.red)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.25)))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .help(line.breakpoints.isEmpty ? "Set a breakpoint" : "Remove the breakpoint")
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundStyle(line.isPC ? (stopped ? Color.accentColor : Color.secondary) : Color.clear)
                Text(String(format: "%08X", line.address)).foregroundStyle(.secondary)
                Text(line.word.map { String(format: "%08X", $0) } ?? "--------").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                Text(line.text)
                Spacer()
                if let source = line.source { Text(source).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(alignment: .leading) {
                GeometryReader { g in
                    if line.heat > 0 {
                        Rectangle().fill(Color.orange.opacity(0.12 + 0.3 * line.heat)).frame(width: max(3, g.size.width * 0.25 * line.heat))
                    }
                }
            }
            .background(line.isPC ? Color.accentColor.opacity(stopped ? 0.18 : 0.08) : Color.clear)
        }
        .font(.system(.body, design: .monospaced))
    }
}

// MARK: Memory

struct MemoryView: View {
    @Bindable var model: DebuggerModel
    @State private var addressText = ""
    @State private var editing: Int?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory").font(.headline)
                Picker("Space", selection: $model.view.memorySpace) {
                    ForEach(DebugMemorySpace.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                TextField("Address", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit {
                        if let a = model.address(addressText) { model.view.memoryAddress = a & ~15 } else { model.message = "Bad address: \(addressText)" }
                    }
                Button { model.view.memoryAddress &-= 256 } label: { Image(systemName: "chevron.up") }
                Button { model.view.memoryAddress &+= 256 } label: { Image(systemName: "chevron.down") }
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let memory = model.snapshot?.memory ?? []
                    let previous = model.previousMemory
                    ForEach(0..<(memory.count / 16), id: \.self) { r in
                        HStack(spacing: 0) {
                            Text(String(format: "%08X", model.view.memoryAddress &+ UInt32(r * 16))).foregroundStyle(.secondary).padding(.trailing, 6)
                            ForEach(0..<16, id: \.self) { c in
                                let i = r * 16 + c
                                let changed = i < previous.count && previous[i] != memory[i]
                                Text(memory[i].map { String(format: "%02X", $0) } ?? "--")
                                    .foregroundStyle(memory[i] == nil ? Color.secondary : (changed ? Color.orange : Color.primary))
                                    .fontWeight(changed ? .bold : .regular)
                                    .padding(.trailing, c == 7 ? 10 : 4)
                                    .onTapGesture(count: 2) { editing = i; editText = memory[i].map { String(format: "%02X", $0) } ?? "" }
                                    .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 { editing = nil } })) {
                                        TextField("Value", text: $editText)
                                            .frame(width: 80).padding()
                                            .onSubmit {
                                                if let v = UInt8(editText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&", with: ""), radix: 16) { model.write(v, at: i) }
                                                editing = nil
                                            }
                                    }
                            }
                            Text(String((0..<16).map { c -> Character in
                                guard let b = memory[r * 16 + c], b >= 32, b < 127 else { return "." }
                                return Character(UnicodeScalar(b))
                            }))
                            .foregroundStyle(.secondary).padding(.leading, 6)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .padding(8)
            }
        }
    }
}

// MARK: Sidebar

struct DebuggerSidebar: View {
    let model: DebuggerModel
    @AppStorage("MacArchDebuggerTab") private var tab = "CPU"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(["CPU", "Breakpoints", "Hardware", "Trace", "Profile", "Log"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case "Breakpoints": BreakpointsView(model: model)
            case "Hardware": HardwareView(model: model)
            case "Trace": TraceView(model: model)
            case "Profile": ProfileView(model: model)
            case "Log": LogView(model: model)
            default: RegistersView(model: model)
            }
        }
    }
}

struct RegisterField: View {
    let model: DebuggerModel
    let name: String
    let value: UInt32
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(width: 100)
            .disabled(!model.isStopped)
            .onAppear { text = String(format: "&%08X", value) }
            .onChange(of: value) { text = String(format: "&%08X", value) }
            .onSubmit {
                let t = text.hasPrefix("&") ? text : "&" + text
                if let v = DebuggerModel.parseNumber(t) { model.setRegister(name, v) } else { text = String(format: "&%08X", value) }
            }
    }
}

struct RegistersView: View {
    let model: DebuggerModel

    var body: some View {
        ScrollView {
            if let s = model.snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(s.registers, id: \.0) { name, value in
                            GridRow {
                                Text(name == "R13" ? "R13 sp" : name == "R14" ? "R14 lr" : name).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                RegisterField(model: model, name: name, value: value)
                                Text("\(value)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(zip(["N", "Z", "C", "V", "I", "F"], [31, 30, 29, 28, 27, 26])), id: \.0) { flag, bit in
                            let set = s.psr & (1 << UInt32(bit)) != 0
                            Button(flag) { model.setRegister(flag, set ? 0 : 1) }
                                .buttonStyle(.bordered)
                                .background(set ? Color.accentColor.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .fontWeight(set ? .bold : .regular)
                                .help(set ? "\(flag) is set" : "\(flag) is clear")
                                .frame(width: 34)
                                .disabled(!model.isStopped)
                        }
                        Picker("Mode", selection: Binding(get: { s.psr & 3 }, set: { model.setRegister("MODE", $0) })) {
                            Text("USR").tag(UInt32(0)); Text("FIQ").tag(UInt32(1)); Text("IRQ").tag(UInt32(2)); Text("SVC").tag(UInt32(3))
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        .disabled(!model.isStopped)
                    }
                    DisclosureGroup("Banked registers") {
                        ForEach(s.banked, id: \.0) { mode, regs in
                            Text("\(mode): " + regs.enumerated().map { String(format: "R%d=%08X", $0.offset + 8, $0.element) }.joined(separator: " "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Instruction \(s.instructions), cycle \(s.ticks)").font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Text("Stack (from R13)").font(.headline)
                    ForEach(s.stack, id: \.0) { a, v in
                        Text(String(format: "%08X  ", a) + (v.map { String(format: "%08X", $0) } ?? "--------"))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(12)
            }
        }
    }
}

struct BreakpointsView: View {
    let model: DebuggerModel
    @State private var address = ""
    @State private var end = ""
    @State private var kind = Debugger.Breakpoint.Kind.execute
    @State private var condition = ""
    @State private var logText = ""

    var body: some View {
        VStack(spacing: 0) {
            List(model.snapshot?.breakpoints ?? []) { b in
                HStack {
                    Toggle("", isOn: Binding(get: { b.enabled }, set: { var c = b; c.enabled = $0; model.updateBreakpoint(c) })).labelsHidden()
                    VStack(alignment: .leading) {
                        Text(title(b)).font(.system(.callout, design: .monospaced))
                        let detail = [b.condition.map { "if \($0)" }, b.logMessage.map { "log \($0)" }, b.hitTarget.map { "from hit \($0)" }, b.mode.map { "in \($0)" }].compactMap { $0 }
                        if !detail.isEmpty { Text(detail.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("\(b.hitCount)").font(.caption).help("Hits")
                    Button { model.removeBreakpoint(b.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Divider()
            Form {
                TextField("Address", text: $address, prompt: Text("&8000 or expression"))
                TextField("To", text: $end, prompt: Text("optional end of range"))
                Picker("Stop on", selection: $kind) {
                    Text("Execute").tag(Debugger.Breakpoint.Kind.execute)
                    Text("Read").tag(Debugger.Breakpoint.Kind.read)
                    Text("Write").tag(Debugger.Breakpoint.Kind.write)
                    Text("Read or write").tag(Debugger.Breakpoint.Kind.access)
                }
                TextField("Condition", text: $condition, prompt: Text("e.g. R0 == &41"))
                TextField("Log", text: $logText, prompt: Text("log instead of stopping: R0={R0}"))
                HStack {
                    Button("Add Breakpoint") { add() }
                    Spacer()
                    Button("Remove All") { model.removeAllBreakpoints() }.disabled(model.snapshot?.breakpoints.isEmpty ?? true)
                }
            }
            .padding(8)
        }
    }

    private func title(_ b: Debugger.Breakpoint) -> String {
        let k = b.kind == .execute ? "exec" : b.kind == .read ? "read" : b.kind == .write ? "write" : "r/w"
        return "\(k) " + String(format: "&%X", b.start) + (b.end != b.start ? String(format: "-&%X", b.end) : "")
    }

    private func add() {
        guard let a = model.address(address) else { model.message = "Bad address: \(address)"; return }
        let e = end.isEmpty ? nil : model.address(end)
        model.addBreakpoint(.init(id: 0, kind: kind, start: kind == .execute ? a & ~3 : a, end: e,
                                  condition: condition.isEmpty ? nil : condition, logMessage: logText.isEmpty ? nil : logText))
        address = ""; end = ""
    }
}

struct HardwareView: View {
    let model: DebuggerModel

    var body: some View {
        List(model.snapshot?.hardware ?? []) { section in
            Section(section.name) {
                ForEach(section.rows) { row in
                    HStack {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value).font(.system(.caption, design: .monospaced)).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct TraceView: View {
    let model: DebuggerModel

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Record the last 100,000 instructions", isOn: Binding(get: { model.snapshot?.tracing ?? false }, set: { model.setTracing($0) }))
                .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(model.snapshot?.trace ?? []) { t in
                    HStack(spacing: 8) {
                        Text(String(format: "%08X", t.pc)).foregroundStyle(.secondary)
                        Text(t.text).frame(width: 200, alignment: .leading)
                        Text(t.registers).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(t.id)
                }
                .onChange(of: model.snapshot?.trace.count) { if let last = model.snapshot?.trace.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct ProfileView: View {
    let model: DebuggerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(model.snapshot?.isProfiling == true ? "Stop Profiling" : "Start Profiling") { model.setProfiling(!(model.snapshot?.isProfiling ?? false)) }
                Spacer()
                if let p = model.snapshot?.profile {
                    Text(String(format: "%d frames, %.0f cycles/frame, %.1f%% in interrupts", p.frames, p.ticksPerFrame, 100 * p.interruptShare))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            if let p = model.snapshot?.profile, p.totalTicks > 0 {
                let total = Double(p.totalTicks)
                List {
                    Section("Routines") {
                        ForEach(Array(p.routines.prefix(30).enumerated()), id: \.offset) { _, r in bar(Double(r.ticks) / total, r.name) }
                    }
                    Section("Busiest instructions") {
                        ForEach(Array(p.hottest.prefix(30).enumerated()), id: \.offset) { _, e in bar(Double(e.ticks) / total, String(format: "&%07X  ×%d", e.address, e.executions)) }
                    }
                }
            } else {
                Text("Start profiling to count the time spent at every instruction. The disassembly shows where the time goes; routines are grouped by symbol (or by 4 KB).")
                    .foregroundStyle(.secondary).padding().frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func bar(_ share: Double, _ name: String) -> some View {
        HStack {
            Text(String(format: "%5.1f%%", 100 * share)).font(.system(.caption, design: .monospaced)).frame(width: 56, alignment: .trailing)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.orange.opacity(0.15)).frame(width: 60, height: 6)
                Rectangle().fill(Color.orange.opacity(0.6)).frame(width: 60 * share, height: 6)
            }
            Text(name).font(.system(.caption, design: .monospaced)).lineLimit(1)
        }
    }
}

struct LogView: View {
    let model: DebuggerModel

    var body: some View {
        List(Array((model.snapshot?.log ?? []).enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading) {
                Text(e.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("cycle \(e.ticks)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.snapshot?.log.isEmpty ?? true {
                Text("Log points' output appears here. Add a breakpoint with a log message to log instead of stopping.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }
}
