import AppKit
import ArchimedesCore
import SwiftUI

/// Window ▸ My Machines: the Archimedes saved with names, to start again as
/// they were left. Machine ▸ Save to My Machines… adds them; Import Machine…
/// adds a machine configuration file.
struct MyMachinesView: View {
    static let windowID = "my-machines"
    static let title = "My Machines"

    @State private var machines = MyMachines.shared
    @State private var selection: UUID?
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var creating = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if machines.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Machines Yet", systemImage: "desktopcomputer")
                    } description: {
                        Text("Create one here, or set an Archimedes up as you like it and choose Machine ▸ Save to My Machines… to keep it with a name. Or import a machine configuration file.")
                    } actions: {
                        Button("Create Machine…") { creating = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 24)], alignment: .leading, spacing: 24) {
                        ForEach(machines.entries) { entry in
                            MachineTile(entry: entry, selected: selection == entry.id, running: machines.running(entry.id) != nil,
                                        revision: machines.revision)
                                .onTapGesture(count: 2) { start(entry.id) }
                                .onTapGesture { selection = entry.id }
                                .contextMenu { menu(entry) }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { machines.reload() }
        .sheet(isPresented: $creating) {
            CreateMachineSheet { id in selection = id }
        }
        .alert("Rename Machine", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = renaming { machines.rename(id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title).font(.largeTitle.weight(.bold))
                Text("Archimedes kept as you left them: the model, processor, memory, monitor, ROM, hard discs and RISC OS's settings. Double-click one to start it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { creating = true } label: {
                Label("Create Machine…", systemImage: "plus")
            }
            .controlSize(.large)
            .help("Set up a new machine: its model, processor, memory, monitor, ROM and hard discs")
            .accessibilityIdentifier("my-machines-create")
            Button {
                if let id = machines.chooseAndImport() { selection = id }
            } label: {
                Label("Import Machine…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .help("Add a machine configuration file (as Export Machine Configuration writes) to My Machines")
            .accessibilityIdentifier("my-machines-import")
            Button {
                if let id = selection { start(id) }
            } label: {
                Label("Start", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(selection.flatMap(machines.entry)?.problem != nil || selection == nil)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func menu(_ entry: MyMachines.Entry) -> some View {
        Button("Start") { start(entry.id) }.disabled(entry.problem != nil)
        Divider()
        Button("Rename…") { newName = entry.name; renaming = entry.id }
        Button("Duplicate") {
            do { try machines.duplicate(entry.id) } catch { MyMachines.alert("Could not duplicate \(entry.name)", "\(error)") }
        }
        Button("Export Machine Configuration…") { machines.export(entry.id) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if selection == entry.id { selection = nil }
            machines.remove(entry.id)
        }
    }

    private func start(_ id: UUID) {
        selection = id
        machines.start(id, openWindow: openWindow)
        // From the welcome screen's way in, it's done its job.
        dismissWindow(id: WelcomeScreen.windowID)
    }
}

/// A saved machine: its screen when saved, its name and what it is.
private struct MachineTile: View {
    let entry: MyMachines.Entry
    let selected: Bool
    let running: Bool
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screen
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.12)), lineWidth: selected ? 3 : 1))
                .overlay(alignment: .topTrailing) {
                    if running {
                        Label("Running", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.green.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline).lineLimit(2)
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let rom { Text(rom).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let problem = entry.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
        }
        .contentShape(Rectangle())
        .help(entry.problem ?? "Double-click to start \(entry.name)")
    }

    @ViewBuilder private var screen: some View {
        if let image = NSImage(contentsOf: entry.screenURL), revision >= 0 {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .background(Color.black)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: entry.configuration?.model.symbolName ?? "desktopcomputer")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        guard let c = entry.configuration else { return "Can't be read" }
        var parts = [c.model.rawValue, c.cpu.displayName, AppSettings.ramLabel(c.ramKB)]
        let discs = c.hardDiscs.compactMap { $0 }.count
        if discs > 0 { parts.append(discs == 1 ? "1 hard disc" : "\(discs) hard discs") }
        return parts.joined(separator: " · ")
    }

    private var rom: String? {
        guard let path = entry.configuration?.romPaths.first else { return nil }
        // As the ROM menus name it (with its size, beside another the same version).
        if let e = AppSettings.shared.romLibrary.first(where: { $0.path == path }) { return AppSettings.shared.label(e) }
        return ROMLibrary.shared.detail(for: path)?.version
    }
}

/// Create Machine…: a new entry set up by hand, to start from the gallery.
private struct CreateMachineSheet: View {
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var name = ""
    @State private var nameEdited = false
    @State private var model = AppSettings.shared.model
    @State private var cpu = AppSettings.shared.model.defaultCPU
    @State private var ramKB = AppSettings.shared.model.defaultRAMKB
    @State private var monitor = MonitorType.standard
    @State private var romPath = ""
    @State private var hardDiscs: [String?] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Machine").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                Picker("Model", selection: $model) {
                    ForEach(MachineModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Processor", selection: $cpu) {
                    ForEach(model.cpuChoices, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Memory", selection: $ramKB) {
                    ForEach(model.ramChoices, id: \.self) { Text(AppSettings.ramLabel($0)).tag($0) }
                }
                Picker("Monitor", selection: $monitor) {
                    ForEach(model.monitorChoices, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("ROM", selection: $romPath) {
                    if roms.isEmpty { Text("No ROM suits the \(model.rawValue)").tag("") }
                    ForEach(roms) { Text(settings.label($0)).tag($0.path) }
                }
                ForEach(0..<model.hardDiscSlots, id: \.self) { drive in
                    LabeledContent("Hard disc \(drive + 4)") {
                        HStack {
                            Text(hardDiscs.indices.contains(drive) ? hardDiscs[drive].map { ($0 as NSString).lastPathComponent } ?? "None" : "None")
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("New…") { newHardDisc(drive) }
                                .help("Make a new, formatted hard disc image for this drive")
                            Button("Choose…") { chooseHardDisc(drive) }
                                .help("Use a hard disc image you have")
                            if hardDiscs.indices.contains(drive), hardDiscs[drive] != nil {
                                Button("Remove") { hardDiscs[drive] = nil }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text(model.hardDiscSlots == 0
                 ? "The first start sets RISC OS's settings to their defaults; it keeps them after that."
                 : "Hard discs are used where they are, not copied. The first start sets RISC OS's settings to their defaults; it keeps them after that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(romPath.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { modelChanged() }
        .onChange(of: model) { modelChanged() }
        .onChange(of: romPath) { suggestName() }
    }

    private var roms: [AppSettings.ROMEntry] { settings.romLibrary.filter { $0.suits(model) } }

    /// A model brings its usual processor, memory and monitor, a ROM that
    /// suits it, and no hard discs (their sector sizes differ).
    private func modelChanged() {
        cpu = model.defaultCPU
        ramKB = model.defaultRAMKB
        monitor = model.monitorChoices.contains(monitor) ? monitor : .standard
        if !roms.contains(where: { $0.path == romPath }) {
            romPath = settings.preferredROM(for: model, like: romPath.isEmpty ? settings.romPath : romPath) ?? ""
        }
        hardDiscs = Array(repeating: nil, count: model.hardDiscSlots)
        suggestName()
    }

    private func suggestName() {
        guard !nameEdited else { return }
        let rom = settings.romLibrary.first { $0.path == romPath }.map { $0.version.components(separatedBy: " (").first ?? $0.version }
        name = rom.map { "\(model.rawValue) with \($0)" } ?? model.rawValue
    }

    /// A new, formatted and empty, hard disc of a chosen size.
    private func newHardDisc(_ drive: Int) {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? model.rawValue : name.trimmingCharacters(in: .whitespaces)
        let file = String("\(base) drive \(drive + 4).hdf".map { "/:".contains($0) ? "-" : $0 })
        guard let (url, geometry, system) = MachineController.chooseNewHardDisc(
            model: model, drive: drive, message: { $0 ? "A new formatted hard disc, with !System and !Scrap, for drive \(drive + 4) of \(base)." : "A new hard disc, formatted and empty, for drive \(drive + 4) of \(base)." }, name: file) else { return }
        do {
            try ADFSFormatter.createFormattedImage(path: url.path, geometry: geometry, name: (url.lastPathComponent as NSString).deletingPathExtension, system: system)
            hardDiscs[drive] = url.path
        } catch {
            MyMachines.alert("Could not create the hard disc", "\(error)")
        }
    }

    private func chooseHardDisc(_ drive: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [MachineController.hardDiscType]
        panel.allowsOtherFileTypes = true
        panel.message = model.hasIDE ? "Choose an IDE hard disc image (.hdf, raw 512-byte sectors) for drive \(drive + 4)"
            : "Choose an ST506 hard disc image (.hdf, raw 256-byte sectors) for drive \(drive + 4)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try HardDiscImage.open(path: url.path, sectorSize: model.hardDiscSectorSize)
            hardDiscs[drive] = url.path
        } catch {
            MyMachines.alert("Could not use \(url.lastPathComponent)", "\(error)")
        }
    }

    private func create() {
        do {
            let id = try MyMachines.shared.create(name: name.trimmingCharacters(in: .whitespaces), model: model, cpu: cpu, ramKB: ramKB,
                                                  monitor: monitor, romPath: romPath, hardDiscs: hardDiscs)
            created(id)
            dismiss()
        } catch {
            MyMachines.alert("Could not create the machine", "\(error)")
        }
    }
}

/// Window ▸ My Machines.
struct MyMachinesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(MyMachinesView.title) { openWindow(id: MyMachinesView.windowID) }
            .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

/// Machine ▸ Save to My Machines… and, for a machine that came from there
/// (or was saved), Update in My Machines.
struct SaveToMyMachinesItems: View {
    let machine: MachineController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Save to My Machines…") { if let machine { SaveToMyMachines.ask(machine, openWindow: openWindow) } }
            .disabled(machine?.host == nil || machine?.isStation == true)
        if let machine, let id = machine.savedMachineID, let entry = MyMachines.shared.entry(id) {
            Button("Update “\(entry.name)” in My Machines") {
                SaveToMyMachines.save(machine, name: entry.name, over: id, openWindow: openWindow)
            }
            .disabled(machine.host == nil)
        }
    }
}

@MainActor
enum SaveToMyMachines {
    /// Asks for a name, then saves the machine as a new entry.
    static func ask(_ machine: MachineController, openWindow: OpenWindowAction) {
        let alert = NSAlert()
        alert.messageText = "Save to My Machines"
        alert.informativeText = "Keeps this \(machine.model.rawValue)'s processor, memory, monitor, ROM, hard discs and RISC OS settings, to start again from My Machines. The hard discs stay where they are."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = MyMachines.shared.suggestedName(for: machine)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        save(machine, name: name.isEmpty ? MyMachines.shared.suggestedName(for: machine) : name, over: nil, openWindow: openWindow)
    }

    static func save(_ machine: MachineController, name: String, over id: UUID?, openWindow: OpenWindowAction) {
        Task {
            do {
                try await MyMachines.shared.save(machine, name: name, over: id)
                openWindow(id: MyMachinesView.windowID)
            } catch {
                MyMachines.alert("Could not save \(name)", "\(error)")
            }
        }
    }
}
