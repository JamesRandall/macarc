import ArchimedesCore
import SwiftUI

/// Machine > Configure Machine: the model, processor, memory, monitor, ROM
/// and hard discs in one place.
///
/// The hardware is chosen as a draft: fitting it restarts the machine (as
/// switching off and on would), so nothing changes until Restart. Hard disc
/// actions restart it themselves, so they act straight away.
struct ConfigureMachineWindow: View {
    let machine: MachineController
    @State private var draft: Draft
    @State private var usage: [Int: ADFSHardDiscWriter.Usage] = [:]
    @State private var tab: Tab

    enum Tab: String, CaseIterable {
        case model, processor, monitor, rom, hardDiscs
    }
    @Environment(\.openWindow) private var openWindow

    struct Draft: Equatable {
        var model: MachineModel
        var cpu: CPUType
        var ramKB: Int
        var monitor: MonitorType
        var romPath: String
    }

    init(machine: MachineController) {
        self.machine = machine
        var d = Self.current(machine)
        // Self-test: MACARCH_SELFTEST_CONFIGURE=A5000 opens with that model chosen.
        if let m = ProcessInfo.processInfo.environment["MACARCH_SELFTEST_CONFIGURE"].flatMap(MachineModel.init(rawValue:)) {
            d.model = m; d.cpu = m.defaultCPU; d.ramKB = m.defaultRAMKB; d.monitor = m.monitorChoices.last ?? .standard
        }
        _draft = State(initialValue: d)
        _tab = State(initialValue: ProcessInfo.processInfo.environment["MACARCH_SELFTEST_CONFIGURE_TAB"].flatMap(Tab.init(rawValue:)) ?? .model)
    }

    static func current(_ m: MachineController) -> Draft {
        Draft(model: m.model, cpu: m.cpu, ramKB: m.ramKB, monitor: m.monitor, romPath: m.romPath ?? "")
    }

    private var current: Draft { Self.current(machine) }
    private var pending: Bool { draft != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            TabView(selection: $tab) {
                page { modelSection }
                    .tabItem { Text("Model") }.tag(Tab.model)
                page { VStack(alignment: .leading, spacing: 24) { processorSection; memorySection } }
                    // Short: the tabs are in the toolbar, and when they don't all fit
                    // beside the window's buttons macOS shows none of them.
                    .tabItem { Text("CPU & Memory") }.tag(Tab.processor)
                page { monitorSection }
                    .tabItem { Text("Monitor") }.tag(Tab.monitor)
                page { romSection }
                    .tabItem { Text("ROM") }.tag(Tab.rom)
                if draft.model.hardDiscSlots > 0 {
                    page { hardDiscSection }
                        .tabItem { Text("Hard Discs") }.tag(Tab.hardDiscs)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // A maximum too, so a size remembered from a taller version is clamped;
        // the minimum width keeps all five tabs in the toolbar.
        .frame(minWidth: 700, idealWidth: 760, maxWidth: 1200, minHeight: 480, idealHeight: 640, maxHeight: 900)
        .safeAreaInset(edge: .bottom, spacing: 0) { restartBar }
        .animation(.snappy(duration: 0.25), value: draft)
        .onChange(of: current) { draft = current }
        .onChange(of: draft.model) { if draft.model.hardDiscSlots == 0 && tab == .hardDiscs { tab = .model } }
        .task(id: machine.hardDiscs) { refreshUsage() }
    }

    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: draft.model.symbolName)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.model.displayName)
                    .font(.title.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Configuration") {
                Button("Import…") { machine.chooseImportConfiguration() }
                Button("Export Current Machine…") { machine.chooseExportConfiguration() }
                    .disabled(machine.host == nil)
                Divider()
                Button("Save to My Machines…") { SaveToMyMachines.ask(machine, openWindow: openWindow) }
                    .disabled(machine.host == nil)
            }
            .disabled(machine.isStation)
            .fixedSize()
        }
    }

    private var summary: String {
        var parts = [draft.cpu.shortName, AppSettings.ramLabel(draft.ramKB), draft.monitor.displayName + " monitor"]
        if let v = AppSettings.shared.romLibrary.first(where: { $0.path == draft.romPath })?.version { parts.append(v) }
        return parts.joined(separator: " · ")
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(nil, detail: "Each model remembers its own processor, memory, monitor and hard discs.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(MachineModel.allCases, id: \.self) { m in
                    ChoiceCard(symbol: m.symbolName, title: m.rawValue, subtitle: m.year, detail: m.blurb,
                               badges: m.badges, selected: draft.model == m, fitted: current.model == m) { choose(m) }
                }
            }
        }
    }

    /// A model brings back what was last fitted to it, as the menus do.
    private func choose(_ m: MachineModel) {
        guard m != draft.model else { return }
        let s = AppSettings.shared
        var d = draft
        d.model = m
        d.cpu = s.cpu(for: m)
        d.ramKB = s.ramKB(for: m)
        d.monitor = s.monitor(for: m)
        if !romSuits(d.romPath, m), let other = AppSettings.shared.preferredROM(for: m, like: d.romPath) {
            d.romPath = other
        }
        draft = d
    }

    // MARK: Processor

    private var processorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Processor", detail: draft.model.cpuChoices.count > 1
                         ? "Upgrade cards took the older machines to an ARM3. The ×2 and ×4 ARM3s go beyond any real one, for games that wanted a RiscPC."
                         : "The \(draft.model.rawValue) has its processor on the board.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(draft.model.cpuChoices, id: \.self) { c in
                    ChoiceCard(symbol: c.symbolName, title: c.shortName, subtitle: c.clock, detail: c.blurb,
                               badges: c.turboShift > 0 ? [.init("Faster than real", .orange)] : [],
                               selected: draft.cpu == c, fitted: current.model == draft.model && current.cpu == c) { draft.cpu = c }
                }
            }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory", detail: draft.model == .a540
                         ? "Each 4 MB beyond the first came on a card with its own slave MEMC. RISC OS 2.00 can't use more than 4 MB: use RISC OS 3."
                         : "Some games want 2 MB or more; the A5000 versions of later ones want 4 MB.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(draft.model.ramChoices, id: \.self) { kb in
                    ChoiceCard(symbol: kb >= 4096 ? "memorychip.fill" : "memorychip", title: AppSettings.ramLabel(kb), subtitle: nil, detail: nil,
                               badges: kb == draft.model.defaultRAMKB ? [.init("As sold", .secondary)] : [],
                               selected: draft.ramKB == kb, fitted: current.model == draft.model && current.ramKB == kb) { draft.ramKB = kb }
                }
            }
        }
    }

    // MARK: Monitor

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(nil, detail: draft.model.hasNewIO
                         ? "The \(draft.model.rawValue) reads the monitor's ID lines and picks a desktop mode to suit."
                         : "Older machines assume a standard monitor; RISC OS's *Configure MonitorType changes that.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(draft.model.monitorChoices, id: \.self) { t in
                    ChoiceCard(symbol: t.symbolName, title: t.shortName, subtitle: t.scanRate, detail: t.blurb, badges: [],
                               selected: draft.monitor == t, fitted: current.model == draft.model && current.monitor == t) { draft.monitor = t }
                }
            }
        }
    }

    // MARK: ROM

    private func romSuits(_ path: String, _ m: MachineModel) -> Bool {
        ROMLibrary.shared.detail(for: path)?.models.contains(m) ?? false
    }

    private var romSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(nil, detail: "The operating system: RISC OS 3 runs everything, RISC OS 2 the original range.")
                Button("Add ROMs…") { openWindow(id: "roms") }
                    .buttonStyle(.link)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(AppSettings.shared.romLibrary) { entry in
                    let detail = ROMLibrary.shared.detail(for: entry.path)
                    let suits = romSuits(entry.path, draft.model)
                    ChoiceCard(symbol: "square.stack.3d.up", title: entry.version, subtitle: nil,
                               detail: suits ? (detail?.known != nil ? "A known good dump." : "Recognised.")
                                   : "Not for the \(draft.model.rawValue): \(detail?.whyNot(draft.model) ?? "it can't be read").",
                               badges: detail.map { [.init($0.sizeKB >= 1024 ? "\($0.sizeKB / 1024) MB" : "\($0.sizeKB) KB", .secondary)] } ?? [],
                               selected: draft.romPath == entry.path, fitted: current.romPath == entry.path) { draft.romPath = entry.path }
                        .disabled(!suits)
                        .opacity(suits ? 1 : 0.5)
                }
            }
        }
    }

    // MARK: Hard discs

    private func refreshUsage() {
        var u: [Int: ADFSHardDiscWriter.Usage] = [:]
        for (i, p) in machine.hardDiscs.enumerated() {
            if let p, let x = try? ADFSHardDiscWriter.usage(path: p) { u[i] = x }
        }
        usage = u
    }

    private var hardDiscSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(nil, detail: draft.model.hasIDE
                         ? "IDE drives, with 512-byte sectors. Changing one restarts the machine."
                         : "ST506 drives, with 256-byte sectors. Changing one restarts the machine.")
            if pending && draft.model != current.model {
                Label("Restart as the \(draft.model.rawValue) to change its hard discs.", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(0..<draft.model.hardDiscSlots, id: \.self) { drive in
                        HardDiscRow(drive: drive, name: machine.hardDiscName(drive), usage: usage[drive], machine: machine)
                    }
                }
                .disabled(pending)
            }
        }
    }

    // MARK: Restart

    private var restartBar: some View {
        Group {
            if pending {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.model != current.model ? "Restart as the \(draft.model.displayName)" : "Restart to fit the changes")
                            .font(.headline)
                        Text("As switching off and on: what's in memory is lost. The floppy stays in its drive.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { draft = current }
                        .keyboardShortcut(.cancelAction)
                    Button("Restart Machine") {
                        machine.setHardware(model: draft.model, cpu: draft.cpu, ramKB: draft.ramKB, monitor: draft.monitor,
                                            romPath: draft.romPath.isEmpty ? nil : draft.romPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: pending)
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let title: String?
    let detail: String

    init(_ title: String?, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Badge: Hashable {
    var text: String
    var colour: Color
    init(_ text: String, _ colour: Color) { self.text = text; self.colour = colour }
}

/// A choice in the style of MacBeeb's memory board cards.
private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let detail: String?
    let badges: [Badge]
    let selected: Bool
    let fitted: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(height: 28)
                    Spacer()
                    ForEach(badges, id: \.self) { b in
                        Text(b.text)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(b.colour.opacity(0.18), in: Capsule())
                            .foregroundStyle(b.colour)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if fitted {
                    Label("Fitted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: detail == nil ? 84 : 130, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(fitted ? "Fitted now" : "")
        .help(detail ?? title)
    }
}

/// One drive: what's in it, how full it is, and what can be done with it.
private struct HardDiscRow: View {
    let drive: Int
    let name: String?
    let usage: ADFSHardDiscWriter.Usage?
    let machine: MachineController

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: name == nil ? "internaldrive" : "internaldrive.fill")
                .font(.system(size: 26))
                .foregroundStyle(name == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Drive :\(drive + 4)").font(.headline)
                    Text(name ?? "Empty").font(.callout).foregroundStyle(.secondary)
                }
                if let u = usage {
                    let used = Double(u.size - u.bytesFree) / Double(max(u.size, 1))
                    ProgressView(value: used)
                        .frame(maxWidth: 220)
                    Text("\(mb(u.size - u.bytesFree)) of \(mb(u.size)) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if name == nil {
                Button("New…") { machine.newHardDisc(drive: drive) }
                Button("Open…") { machine.openHardDisc(drive: drive) }
            } else {
                Button("Add Files…") { machine.addFilesToHardDisc(drive: drive) }
                Menu("More") {
                    Button("Resize…") { machine.resizeHardDisc(drive: drive) }
                    Button("Open Another…") { machine.openHardDisc(drive: drive) }
                    Button("New Hard Disc…") { machine.newHardDisc(drive: drive) }
                    Button("New Hard Disc from Files…") { machine.newHardDiscFromFiles(drive: drive) }
                    Divider()
                    Button("Remove") { machine.ejectHardDisc(drive: drive) }
                }
                .fixedSize()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func mb(_ n: Int) -> String { String(format: "%.1f MB", Double(n) / 1_048_576) }
}

// MARK: - Descriptions

extension MachineModel {
    var symbolName: String {
        switch self {
        case .a3000, .a3010, .a3020: "keyboard"
        case .a540: "server.rack"
        default: "desktopcomputer"
        }
    }

    var year: String {
        switch self {
        case .a305, .a310: "1987"
        case .a3000, .a410, .a420, .a440: "1989"
        case .a540: "1990"
        case .a5000: "1991"
        case .a3010, .a3020, .a4000: "1992"
        }
    }

    var blurb: String {
        switch self {
        case .a305: "The first Archimedes: an 8 MHz ARM2 and 512 KB."
        case .a310: "The launch machine with 1 MB: the one most people saw first."
        case .a3000: "The keyboard computer for schools and homes, with the BBC badge."
        case .a410: "The 400 series: room for four expansion cards and an ST506 hard disc."
        case .a420: "The 400 series with 2 MB and an ST506 hard disc."
        case .a440: "The 400 series with 4 MB and an ST506 hard disc: the top model of 1989."
        case .a540: "The workstation: an ARM3 as standard and up to 16 MB."
        case .a5000: "A 25 MHz ARM3, an IDE drive, multisync monitors and RISC OS 3."
        case .a3010: "The ARM250 keyboard computer for the home."
        case .a3020: "The ARM250 keyboard computer with an internal IDE drive."
        case .a4000: "The ARM250 in a desktop box, with an IDE hard disc."
        }
    }

    var badges: [Badge] {
        var b: [Badge] = []
        if hasIDE { b.append(.init("IDE", .blue)) } else if hardDiscSlots > 0 { b.append(.init("ST506", .blue)) }
        if hasNewIO { b.append(.init("RISC OS 3", .purple)) }
        return b
    }
}

extension CPUType {
    var shortName: String {
        switch self {
        case .arm2: "ARM2"
        case .arm3: "ARM3"
        case .arm250: "ARM250"
        case .arm3x2: "ARM3 ×2"
        case .arm3x4: "ARM3 ×4"
        }
    }

    var clock: String {
        switch self {
        case .arm2: "8 MHz"
        case .arm3: "24 MHz"
        case .arm250: "12 MHz"
        case .arm3x2: "48 MHz"
        case .arm3x4: "96 MHz"
        }
    }

    var symbolName: String {
        switch self {
        case .arm2: "cpu"
        case .arm3: "cpu.fill"
        case .arm250: "square.grid.3x3.middle.filled"
        case .arm3x2: "hare"
        case .arm3x4: "hare.fill"
        }
    }

    var blurb: String {
        switch self {
        case .arm2: "The original: no cache, at the memory's speed."
        case .arm3: "A 4 KB cache: about four times an ARM2."
        case .arm250: "ARM2, MEMC, VIDC and IOC on one chip."
        case .arm3x2: "Only the processor speeds up, so games keep real time."
        case .arm3x4: "Doom's demo goes from 4 frames a second to 9."
        }
    }
}

extension MonitorType {
    var shortName: String {
        switch self {
        case .standard: "Standard"
        case .multisync: "Multisync"
        case .vga: "VGA"
        }
    }

    var scanRate: String {
        switch self {
        case .standard: "15 kHz"
        case .multisync: "15–35 kHz"
        case .vga: "31 kHz"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: "tv"
        case .multisync: "display"
        case .vga: "rectangle.connected.to.line.below"
        }
    }

    var blurb: String {
        switch self {
        case .standard: "TV-rate modes, as most owners had: games' native screens."
        case .multisync: "Everything: TV-rate modes, and 640 × 480 and above."
        case .vga: "VGA modes only: 640 × 480, no TV-rate screens."
        }
    }
}
