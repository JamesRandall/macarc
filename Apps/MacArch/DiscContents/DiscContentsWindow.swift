import AppKit
import ArchimedesCore
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Show Disc Contents: the files on the floppy and hard discs in a
/// machine's drives, which drag out to Finder (typed with ",xxx" suffixes)
/// and in from it, and can be renamed, retyped, relocked and deleted, with
/// undo.
struct DiscContentsWindow: View {
    static let windowID = "disc-contents"
    let machine: MachineController
    @State private var model: DiscContentsModel
    @State private var nameText = ""
    @State private var editing: ADFSVolume.Entry?
    @State private var namingDirectory = false
    @FocusState private var nameFocused: Bool
    @Environment(\.undoManager) private var undoManager

    init(machine: MachineController) {
        self.machine = machine
        _model = State(initialValue: DiscContentsModel(machine: machine))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.problem == nil, model.volume != nil {
                header
                Divider()
            }
            if let problem = model.problem {
                ContentUnavailableView {
                    Label(problem, systemImage: model.drive == .floppy ? "opticaldiscdrive" : "internaldrive")
                } actions: {
                    if model.isEmptyFloppy {
                        HStack {
                            Menu("New Disc") {
                                ForEach(ADFSFloppyFormatter.Format.allCases, id: \.self) { f in
                                    Button(f.name) { machine.insertBlankDisc(f) }
                                }
                            }
                            .fixedSize()
                            Button("Insert Disc…") { machine.openDisc() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.volume == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiscFileTable(model: model, onInfo: { editing = $0 })
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 320)
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Drive", selection: $model.drive) {
                    ForEach(model.drives, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("The floppy drive, and the hard discs fitted")
            }
            ToolbarItemGroup {
                Button("Add Files…", systemImage: "plus") { addFiles() }
                    .help("Copy Mac files and folders onto the disc")
                    .disabled(model.volume == nil)
                Button("New Directory", systemImage: "folder.badge.plus") { namingDirectory = true }
                    .help("Make a directory")
                    .disabled(model.volume == nil)
                Button("Export…", systemImage: "square.and.arrow.up") { exportSelection() }
                    .help("Copy the selected files to a folder on the Mac")
                    .disabled(model.selection.isEmpty)
                Button("Get Info", systemImage: "info.circle") { editing = model.selectedItems.first }
                    .help("Rename, retype or lock the selected file")
                    .disabled(model.selection.count != 1)
                Button("Delete", systemImage: "trash") { model.delete(model.selectedItems, undoManager: undoManager) }
                    .help("Delete the selected files and directories")
                    .disabled(model.selection.isEmpty)
            }
        }
        .onAppear {
            if let d = machine.discContentsDrive, model.drives.contains(d) { model.drive = d }
            model.reload()
        }
        .onChange(of: machine.discContentsDrive) {
            if let d = machine.discContentsDrive, model.drives.contains(d) { model.drive = d }
        }
        .onChange(of: machine.discName) { model.reload() }
        .onChange(of: machine.hardDiscs) { model.reload() }
        .onChange(of: machine.host.map(ObjectIdentifier.init)) { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.reload() }
        .task {
            // RISC OS's own writes show up as they happen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                await model.refreshIfChanged()
            }
        }
        .onChange(of: model.discName, initial: true) {
            if !nameFocused { nameText = model.discName }
        }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil; model.alertTitle = DiscContentsModel.cantChange } })) {
            Button("OK") { model.alert = nil; model.alertTitle = DiscContentsModel.cantChange }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(item: $editing) { e in
            FileInfoSheet(entry: e, oldDirectories: model.volume?.hasOldDirectories ?? false) { name, load, exec, attributes in
                model.update(e, name: name, load: load, exec: exec, attributes: attributes, undoManager: undoManager)
            }
        }
        .sheet(isPresented: $namingDirectory) {
            NameSheet(title: "New Directory", prompt: "Make") { name in
                model.makeDirectory(name, undoManager: undoManager)
            }
        }
    }

    private var windowTitle: String {
        let disc: String? = switch model.drive {
        case .floppy: machine.discName
        case .hard(let slot): machine.hardDiscName(slot)
        }
        return model.drive.name + (disc.map { " — \($0)" } ?? "")
    }

    private func commitName() {
        if ADFSVolume.isValidDiscName(nameText) {
            model.setDiscName(nameText, undoManager: undoManager)
        } else {
            nameText = model.discName
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Disc name", text: $nameText, prompt: Text("No name"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .focused($nameFocused)
                .onSubmit { commitName() }
                .onChange(of: nameText) {
                    if nameText.count > 10 { nameText = String(nameText.prefix(10)) }
                }
                .help("The disc’s name, as the Filer shows it (*NameDisc)")
            Picker("Boot:", selection: Binding(get: { model.bootOption }, set: { model.setBootOption($0, undoManager: undoManager) })) {
                Text("Off").tag(0)
                Text("Load").tag(1)
                Text("Run").tag(2)
                Text("Exec").tag(3)
            }
            .fixedSize()
            .help("What a Shift-start does with the root’s !Boot (*Opt 4)")
            Spacer()
            Text(model.summary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.problem == nil, model.volume != nil {
                Button(":\(model.drive.number).$") { model.goUp(to: 0) }
                    .buttonStyle(.link)
                ForEach(Array(model.path.enumerated()), id: \.offset) { depth, name in
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                    Button(name) { model.goUp(to: depth + 1) }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            if model.waiting {
                ProgressView().controlSize(.small)
                Text(model.drive == .floppy ? "Waiting for the floppy drive to stop…" : "Waiting for the hard disc to be still…")
            } else if model.drive == .floppy && machine.disc.modified && model.volume != nil {
                Text(machine.disc.savable ? "Changes are in memory until File ▸ Save Disc Changes." : "Changes to this image can’t be saved back to it.")
            } else if model.drive != .floppy && model.volume != nil {
                Text("Changing a hard disc restarts the machine.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "A \",xxx\" suffix on a name gives its RISC OS type; .bas text becomes a BASIC program; folders become directories."
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls, undoManager: undoManager)
    }

    private func exportSelection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Files are named with their RISC OS types (\",fff\" for Text, and so on), so they come back in as they were."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try model.export(model.selectedItems, to: folder)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: The file list

/// The disc's files in an NSTableView, for Finder-style dragging: out as
/// file promises, in as file URLs (onto a directory's row to go into it).
struct DiscFileTable: NSViewRepresentable {
    let model: DiscContentsModel
    var onInfo: (ADFSVolume.Entry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onInfo: onInfo)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        for (id, title, width) in [("name", "Name", 190.0), ("type", "Type", 90.0), ("size", "Size", 70.0),
                                   ("date", "Modified", 140.0), ("access", "Access", 60.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = model.sortOrder
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = context.coordinator.contextMenu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onInfo = onInfo
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: DiscContentsModel
        var onInfo: (ADFSVolume.Entry) -> Void
        weak var table: NSTableView?
        private var shown: [ADFSVolume.Entry] = []
        let contextMenu = NSMenu()
        private let dates: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        init(model: DiscContentsModel, onInfo: @escaping (ADFSVolume.Entry) -> Void) {
            self.model = model
            self.onInfo = onInfo
            super.init()
            contextMenu.delegate = self
        }

        func update() {
            guard let table else { return }
            if shown != model.items {
                shown = model.items
                table.reloadData()
            }
            let rows = IndexSet(shown.indices.filter { model.selection.contains(shown[$0].id) })
            if table.selectedRowIndexes != rows {
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < shown.count else { return nil }
            let e = shown[row]
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = e.name
                cell.imageView?.image = Self.icon(e)
            case "type": cell.textField?.stringValue = DiscContentsModel.typeName(e)
            case "size":
                cell.textField?.stringValue = e.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(e.length), countStyle: .file)
            case "date": cell.textField?.stringValue = e.date.map(dates.string) ?? ""
            default: cell.textField?.stringValue = e.access
            }
            return cell
        }

        static func icon(_ e: ADFSVolume.Entry) -> NSImage {
            let type: UTType = if e.isApplication {
                .applicationBundle
            } else if e.isDirectory {
                .folder
            } else {
                switch e.fileType {
                case 0xFFF?, 0xFEB?: .plainText
                case 0xFFB?, 0xFD1?: .sourceCode
                case 0xFF9?, 0x695?, 0xC85?, 0xB60?, 0xFF0?, 0x69C?, 0xAFF?: .image
                case 0xFF8?, 0xFFA?, 0xFFC?, 0xFE6?: .unixExecutable
                case 0xFAF?: .html
                case 0xADF?: .pdf
                case 0xA91?, 0xDDC?, 0xD94?, 0xF89?: .archive
                default: .data
                }
            }
            return NSWorkspace.shared.icon(for: type)
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue == "access" {
                text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            }
            if id.rawValue == "size" { text.alignment = .right }
            cell.addSubview(text)
            cell.textField = text
            var constraints = [text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                               text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                image.widthAnchor.constraint(equalToConstant: 16),
                                image.heightAnchor.constraint(equalToConstant: 16),
                                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
            if model.selection != ids { model.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            model.sortOrder = tableView.sortDescriptors
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < shown.count else { return }
            openOrInfo(shown[row])
        }

        func openOrInfo(_ e: ADFSVolume.Entry) {
            if e.isDirectory { model.open(e) } else { onInfo(e) }
        }

        func deleteSelection() {
            model.delete(model.selectedItems, undoManager: table?.undoManager)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let entries = model.selectedItems
            guard !entries.isEmpty else { return }
            if entries.count == 1 {
                let e = entries[0]
                if e.isDirectory { menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "").target = self }
                menu.addItem(withTitle: "Get Info", action: #selector(infoForSelected), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Export…", action: #selector(exportSelected), keyEquivalent: "").target = self
            if entries.count == 1, model.isBASIC(entries[0]) {
                menu.addItem(withTitle: "Export as Text…", action: #selector(exportSelectedAsText), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        }

        @objc private func openSelected() { if let e = model.selectedItems.first { openOrInfo(e) } }
        @objc private func infoForSelected() { if let e = model.selectedItems.first { onInfo(e) } }

        @objc private func exportSelected() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do { try model.export(model.selectedItems, to: folder) } catch { NSAlert(error: error).runModal() }
        }

        @objc private func exportSelectedAsText() { if let e = model.selectedItems.first { model.exportAsText(e) } }
        @objc private func deleteSelected() { deleteSelection() }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < shown.count, let source = model.source else { return nil }
            let e = shown[row]
            let provider = NSFilePromiseProvider(fileType: (e.isDirectory ? UTType.folder : UTType.data).identifier, delegate: FilePromises.shared)
            provider.userInfo = FilePromises.Promise(entry: e, source: source, path: model.path) { [weak model] skipped in
                model?.showSkipped(skipped)
            }
            return provider
        }

        // MARK: Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) !== tableView, model.volume != nil else { return [] }
            // Onto a directory: into it. Anywhere else: here.
            if dropOperation == .on, row < shown.count, shown[row].isDirectory { return .copy }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let into = row >= 0 && row < shown.count && shown[row].isDirectory ? shown[row].name : nil
            model.add(urls, into: into, undoManager: tableView.undoManager)
            return true
        }
    }
}

/// Return opens a directory or a file's info, Delete deletes, Command-I
/// shows info, Command-Up goes up a directory.
final class FileTableView: NSTableView {
    weak var coordinator: DiscFileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let selected = coordinator?.model.selectedItems ?? []
        switch event.keyCode {
        case 51, 117:
            coordinator?.deleteSelection()
        case 36, 76:
            if selected.count == 1 { coordinator?.openOrInfo(selected[0]) }
        case 126 where event.modifierFlags.contains(.command):
            if let m = coordinator?.model, !m.path.isEmpty { m.goUp(to: m.path.count - 1) }
        case 125 where event.modifierFlags.contains(.command):
            if selected.count == 1, selected[0].isDirectory { coordinator?.model.open(selected[0]) }
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "i", selected.count == 1 {
                coordinator?.onInfo(selected[0])
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Writes dragged-out files where Finder asks.
final class FilePromises: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = FilePromises()

    struct Promise {
        var entry: ADFSVolume.Entry
        var source: DiscContentsModel.ExportSource
        var path: [String]
        /// Told of files left out (unreadable, on a copy protected disc).
        var skipped: @MainActor ([String]) -> Void
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let promise = provider.userInfo as? Promise else { return "File" }
        return ADFSExport.macName(promise.entry)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let promise = provider.userInfo as? Promise else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        do {
            let skipped = try ADFSExport.write(promise.entry, from: promise.source.volume(), at: promise.path, to: url)
            if !skipped.isEmpty { Task { @MainActor in promise.skipped(skipped) } }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

// MARK: Sheets

/// A file's (or directory's) name, type or addresses, date and access.
struct FileInfoSheet: View {
    let entry: ADFSVolume.Entry
    /// An L, M or S disc: ASCII names, and no public access.
    var oldDirectories = false
    var onSave: (String, UInt32, UInt32, UInt8) -> Void
    @State private var name = ""
    @State private var typed = true
    @State private var typeText = ""
    @State private var date = Date()
    @State private var load = ""
    @State private var exec = ""
    @State private var locked = false
    @State private var ownerRead = true
    @State private var ownerWrite = true
    @State private var publicRead = false
    @State private var publicWrite = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name:", text: $name)
            if !entry.isDirectory {
                Picker("Kind:", selection: $typed) {
                    Text("Typed and dated").tag(true)
                    Text("Load and execution addresses").tag(false)
                }
                if typed {
                    TextField("Type:", text: $typeText, prompt: Text("Text, BASIC, Obey, &FFD…"))
                    DatePicker("Modified:", selection: $date)
                } else {
                    TextField("Load address:", text: $load).font(.body.monospaced())
                    TextField("Execution address:", text: $exec).font(.body.monospaced())
                }
                LabeledContent("Size:") {
                    Text("\(entry.length) bytes (&\(String(entry.length, radix: 16, uppercase: true)))")
                }
            }
            LabeledContent("Access:") {
                VStack(alignment: .leading) {
                    Toggle("Locked", isOn: $locked)
                    HStack {
                        Toggle("Read", isOn: $ownerRead)
                        Toggle("Write", isOn: $ownerWrite)
                        Text("(you)").foregroundStyle(.secondary)
                    }
                    if !oldDirectories {
                        HStack {
                            Toggle("Read", isOn: $publicRead)
                            Toggle("Write", isOn: $publicWrite)
                            Text("(others, on a network)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .navigationTitle("Info for “\(entry.name)”")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let (l, e) = addresses ?? (entry.load, entry.exec)
                    onSave(name, l, e, attributes)
                    dismiss()
                }
                .disabled(problem != nil)
            }
        }
        .onAppear {
            name = entry.name
            typed = entry.isTyped
            typeText = entry.fileType.map(RISCOSFileType.name) ?? "Data"
            date = entry.date ?? Date()
            load = String(format: "%08X", entry.load)
            exec = String(format: "%08X", entry.exec)
            let a = entry.attributes
            locked = a & 0x04 != 0
            ownerRead = a & 0x01 != 0
            ownerWrite = a & 0x02 != 0
            publicRead = a & 0x10 != 0
            publicWrite = a & 0x20 != 0
        }
    }

    private var attributes: UInt8 {
        (ownerRead ? 0x01 : 0) | (ownerWrite ? 0x02 : 0) | (locked ? 0x04 : 0) | (publicRead ? 0x10 : 0) | (publicWrite ? 0x20 : 0)
    }

    private var addresses: (UInt32, UInt32)? {
        if entry.isDirectory { return (entry.load, entry.exec) }
        if typed {
            guard let t = RISCOSFileType.type(named: typeText) else { return nil }
            return ADFSVolume.stamp(type: t, date: date)
        }
        guard let l = Self.hex(load), let e = Self.hex(exec) else { return nil }
        return (l, e)
    }

    private var problem: String? {
        if !ADFSVolume.isValidName(name) { return "Up to 10 characters, without spaces or $ & @ ^ % \\ : . # * \" |" }
        if oldDirectories && !name.unicodeScalars.allSatisfy({ $0.isASCII }) { return "Names on this disc are plain ASCII: no accented letters or hard spaces." }
        if addresses == nil {
            return typed ? "A type is a name such as Text or BASIC, or three hex digits (&FFF)." : "Addresses are up to 8 hex digits."
        }
        return nil
    }

    static func hex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces).uppercased()
        if digits.hasPrefix("&") { digits.removeFirst() } else if digits.hasPrefix("0X") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count <= 8 else { return nil }
        return UInt32(digits, radix: 16)
    }
}

/// Asks for a name.
struct NameSheet: View {
    let title: String
    let prompt: String
    var onDone: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name:", text: $name)
                .onChange(of: name) {
                    if name.count > 10 { name = String(name.prefix(10)) }
                }
                .onSubmit {
                    guard ADFSVolume.isValidName(name) else { return }
                    onDone(name)
                    dismiss()
                }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(prompt) {
                    onDone(name)
                    dismiss()
                }
                .disabled(!ADFSVolume.isValidName(name))
            }
        }
    }
}
