import AppKit
import ArchimedesCore
import SwiftUI

/// The studio's side panel: the network as a whole, or the machine (or
/// clock) selected. (After MacBeeb's.)
struct NetworkInspector: View {
    @Bindable var session: NetworkSession
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openConfigure: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.selection.count == 1, let node = session.node(session.selection.first!) {
                    if node.isMachine {
                        MachineInspector(session: session, node: node, openStation: openStation,
                                         openDebugger: openDebugger, openConfigure: openConfigure)
                            .id(node.id)
                    } else {
                        ClockInspector(session: session, node: node)
                    }
                } else if session.selection.count > 1 {
                    selectionSummary
                } else {
                    networkSummary
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Network") {
                LabeledContent("Name") {
                    TextField("Name", text: Binding(get: { session.project.name },
                                                    set: { name in session.update { $0.name = name } }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Machines", value: "\(session.project.stations.count), \(session.controllers.count) on")
                LabeledContent("Clock", value: session.project.hasClock ? "Fitted" : "None")
                if session.status.speed > 0 && !session.controllers.isEmpty {
                    LabeledContent("Speed", value: String(format: "%.0f%% of real time", session.status.speed * 100)
                                   + (session.status.threads > 1 ? " on \(session.status.threads) cores" : ""))
                }
            }
            InspectorSection("Problems") {
                if session.project.problems.isEmpty {
                    Label("None", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.project.problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            InspectorSection("Debugging") {
                Toggle("Pause the network at a breakpoint", isOn: Binding(
                    get: { session.network.pausesOnBreakpoint },
                    set: { session.network.setPauseOnBreakpoint($0) }))
                Text("When one machine stops in its debugger, the others stop too, so none of them times out waiting for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection("Canvas") {
                Toggle("Snap to grid", isOn: Binding(get: { session.project.canvas.snapToGrid },
                                                     set: { on in session.update { $0.canvas.snapToGrid = on } }))
            }
            InspectorSection("File") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
                Text(session.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectionSummary: some View {
        let ids = session.selection
        let machines = ids.compactMap { session.node($0) }.filter(\.isMachine)
        return InspectorSection("\(ids.count) Selected") {
            Button("Power On") { machines.forEach { session.powerOn($0.id) } }
            Button("Power Off") { machines.forEach { session.powerOff($0.id) } }
            Button("Reset") { machines.forEach { session.reset($0.id) } }
        }
    }
}

/// A titled group of rows.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

struct MachineInspector: View {
    let session: NetworkSession
    let node: NetworkNode
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openConfigure: (UUID) -> Void
    @State private var name = ""
    @State private var number = ""
    @State private var numberProblem: String?

    var body: some View {
        let controller = session.controllers[node.id]
        let setup = node.setup ?? StationSetup(model: .a3000)
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(node.kind.displayName) {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { session.rename(node.id, to: name) }
                }
                LabeledContent("Station") {
                    TextField("Station", text: $number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 64)
                        .onSubmit(applyNumber)
                        .help("1 to 254; each machine on a network needs its own. RISC OS reads it from CMOS when it starts, so a machine that's on restarts.")
                }
                if let numberProblem {
                    Label(numberProblem, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Role") {
                    Picker("Role", selection: Binding(get: { node.kind }, set: { kind in session.update { $0[node.id]?.kind = kind } })) {
                        ForEach([NetworkNode.Kind.station, .fileServer], id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
                if !(node.kind == .fileServer && node.runsLevel4 == true) {
                    LabeledContent("Starts up") {
                        Picker("Starts up", selection: Binding(get: { node.startup }, set: { session.setStartup(node.id, $0) })) {
                            Text("From its own discs").tag(NetworkStartup?.none)
                            ForEach(NetworkStartup.allCases, id: \.self) { Text($0.title).tag(NetworkStartup?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    .help(startupHelp)
                }
            }
            .onAppear {
                name = node.name
                number = node.stationNumber.map(String.init) ?? ""
            }
            .onChange(of: node.name) { name = node.name }
            .onChange(of: node.stationNumber) { number = node.stationNumber.map(String.init) ?? "" }

            if node.kind == .fileServer {
                InspectorSection("File Server") {
                    if let line = controller?.consoleLine {
                        LabeledContent("Console", value: line)
                            .font(.callout.monospaced())
                    }
                    if node.runsLevel4 == true {
                        Label("Level 4 File Server set up", systemImage: "checkmark.circle")
                        Text("Its hard disc starts the server when the machine does, and the server shares that disc. On the other machines, *I AM SYST at the command line logs on (no password); in the desktop, the Econet icon on the icon bar logs on and opens the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("A file server is an Archimedes running Acorn's Level 4 File Server, which shares its hard disc with the other machines. Set Up Level 4 makes it one: MacArch includes Level 4, and makes a hard disc that starts it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(node.runsLevel4 == true ? "Set Up Again" : "Set Up Level 4") { session.setUpLevel4(node.id) }
                        .help("Makes a new hard disc for the server with Level 4 on it. The server's old hard disc is replaced.")
                    Text("RISC OS 3.10 and 3.11 machines should load !NetUtils (it's on the server) before copying files of 128K or more: without it, they can be corrupted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorSection("Machine") {
                LabeledContent("Model") {
                    Picker("Model", selection: Binding(get: { setup.model }, set: { model in
                        session.setSetup(node.id, StationSetup(model: model, rom: setup.rom))
                    })) {
                        ForEach(MachineModel.allCases.filter(\.takesEconet), id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                LabeledContent("Processor") {
                    Picker("Processor", selection: Binding(get: { setup.cpu }, set: { cpu in
                        var s = setup; s.cpu = cpu; session.setSetup(node.id, s)
                    })) {
                        ForEach(setup.model.cpuChoices, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                LabeledContent("Memory") {
                    Picker("Memory", selection: Binding(get: { setup.ramKB }, set: { kb in
                        var s = setup; s.ramKB = kb; session.setSetup(node.id, s)
                    })) {
                        ForEach(setup.model.ramChoices, id: \.self) { Text(AppSettings.ramLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                LabeledContent("ROM") {
                    Picker("ROM", selection: Binding(get: { session.romPath(for: setup) ?? "" }, set: { path in
                        var s = setup
                        s.rom = AppSettings.shared.romLibrary.first { $0.path == path }?.version
                        session.setSetup(node.id, s)
                    })) {
                        ForEach(AppSettings.shared.romLibrary) { Text($0.version).tag($0.path) }
                    }
                    .labelsHidden()
                }
                Button("Configure Machine…") {
                    if controller == nil { session.powerOn(node.id) }
                    openConfigure(node.id)
                }
                .help("The machine's Configure window: model, processor, monitor, ROM and hard discs")
            }

            InspectorSection("Power") {
                Toggle("On", isOn: Binding(get: { controller != nil }, set: { on in on ? session.powerOn(node.id) : session.powerOff(node.id) }))
                    .toggleStyle(.switch)
                if controller != nil {
                    Toggle("Suspended", isOn: Binding(get: { session.isSuspended(node.id) }, set: { session.setSuspended(node.id, $0) }))
                        .help("It stops where it is while the rest of the network runs on, so other machines waiting for it time out")
                    HStack {
                        Button("Reset") { session.reset(node.id) }
                        Button("Power Cycle") { session.coldBoot(node.id) }
                            .help("Switch it off and on again")
                    }
                }
            }

            InspectorSection("Discs") {
                HStack {
                    Text("Floppy")
                        .foregroundStyle(.secondary)
                    Text(node.discs[0]?.displayName ?? "Empty")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(node.discs[0] == nil ? .secondary : .primary)
                    Spacer()
                    Menu {
                        Button("Insert Disc…") { session.chooseDisc(for: node.id) }
                        Button("Eject") { session.eject(node.id) }
                            .disabled(node.discs[0] == nil)
                    } label: {
                        Image(systemName: "opticaldiscdrive")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if setup.model.hardDiscSlots > 0 {
                    ForEach(0..<setup.model.hardDiscSlots, id: \.self) { drive in
                        HStack {
                            Text("Hard disc :\(drive + 4)")
                                .foregroundStyle(.secondary)
                            Text(node.hardDiscs[drive]?.displayName ?? "None")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(node.hardDiscs[drive] == nil ? .secondary : .primary)
                        }
                    }
                }
                Text("The network keeps its own copies of its discs, so the machines never change your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Window") {
                    if controller == nil { session.powerOn(node.id) }
                    openStation(node.id)
                }
                Button("Debugger") { openDebugger(node.id) }
                    .disabled(controller == nil)
            }
        }
    }

    private var startupHelp: String {
        switch node.startup {
        case nil: "It starts from its own discs, as its CMOS says"
        case .netFS: "NetFS is selected at start-up, with the file server on station 254: *I AM (or the Econet icon) logs on. A machine that's on restarts."
        case .networkBoot: "At power-on NetFS logs on to station 254 as BOOT and runs the boot file in BOOT's directory, as a school's network boot did. A machine that's on restarts."
        case .hardDisc: "It boots from its hard disc (ADFS drive 4), with the file server on station 254 for anything that logs on. A machine that's on restarts."
        }
    }

    private func applyNumber() {
        guard let value = Int(number.trimmingCharacters(in: .whitespaces)) else {
            numberProblem = "A station number is a number from 1 to 254"
            return
        }
        numberProblem = session.setStationNumber(node.id, to: value)
        if numberProblem != nil {
            number = node.stationNumber.map(String.init) ?? ""
        }
    }
}

struct ClockInspector: View {
    let session: NetworkSession
    let node: NetworkNode

    var body: some View {
        InspectorSection("Network Clock") {
            LabeledContent("Rate") {
                Picker("Rate", selection: Binding(get: { node.clockRate ?? EconetTime.defaultClockRate },
                                                  set: { rate in session.update { $0[node.id]?.clockRate = rate } })) {
                    ForEach(EconetTime.clockRates, id: \.self) { Text(ClockCard.rateText($0)).tag($0) }
                }
                .labelsHidden()
            }
            Text("An Econet carries nothing without a clock: the clock box sets the speed every station sends and receives at.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
