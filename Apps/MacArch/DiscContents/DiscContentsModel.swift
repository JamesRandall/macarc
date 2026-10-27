import AppKit
import ArchimedesCore
import Observation
import UniformTypeIdentifiers

/// A drive whose disc the Disc Contents window shows.
enum DiscDrive: Hashable, Sendable {
    case floppy
    /// A hard disc slot: 0 is RISC OS's drive :4, 1 is :5.
    case hard(Int)

    var number: Int {
        switch self {
        case .floppy: 0
        case .hard(let slot): slot + 4
        }
    }

    var name: String {
        switch self {
        case .floppy: "Floppy :0"
        case .hard(let slot): "Hard Disc :\(slot + 4)"
        }
    }
}

/// What's on the discs in a machine's drives, for the Disc Contents window,
/// and the changes made there.
///
/// A floppy is changed as RISC OS's own writes change it: once its drive
/// has been still for a moment, the change goes into the disc in the drive
/// (so it's saved, or not, with the machine's own changes), with a new disc
/// ID and the disc-changed signal, so RISC OS reads it afresh. A hard disc
/// is changed in its file, with the machine's writes held off, and the
/// machine then restarts: RISC OS keeps a hard disc's map in memory.
@MainActor
@Observable
final class DiscContentsModel {
    let machine: MachineController

    var drive = DiscDrive.floppy {
        didSet {
            guard drive != oldValue else { return }
            path = []
            selection = []
            volume = nil
            reload()
        }
    }

    /// The directories opened from the root, innermost last.
    var path: [String] = []
    private(set) var volume: ADFSVolume?
    /// Where `volume`'s bytes came from, for dragging files out.
    private(set) var source: ExportSource?
    /// Why the disc can't be shown, if it can't.
    private(set) var problem: String?
    private(set) var items: [ADFSVolume.Entry] = []
    var selection: Set<String> = []
    var sortOrder: [NSSortDescriptor] = [NSSortDescriptor(key: "name", ascending: true)] {
        didSet { sortItems() }
    }

    /// Waiting for a drive to be still before changing its disc.
    private(set) var waiting = false
    var alert: String?
    var alertTitle = DiscContentsModel.cantChange
    nonisolated static let cantChange = "The disc can’t be changed"

    init(machine: MachineController) {
        self.machine = machine
    }

    /// The floppy drive, and the hard discs fitted.
    var drives: [DiscDrive] {
        [.floppy] + machine.hardDiscs.indices.filter { machine.hardDiscs[$0] != nil && $0 < machine.model.hardDiscSlots }.map { .hard($0) }
    }

    var isEmptyFloppy: Bool { drive == .floppy && machine.discName == nil }

    var discName: String { volume?.discName ?? "" }
    var bootOption: Int { volume?.bootOption ?? 0 }

    var summary: String {
        guard let volume else { return "" }
        let free = ByteCountFormatter.string(fromByteCount: Int64(volume.freeBytes), countStyle: .binary)
        return "\(volume.formatName) · \(free) free"
    }

    var selectedItems: [ADFSVolume.Entry] { items.filter { selection.contains($0.id) } }

    // MARK: Reading

    /// Where a disc's bytes can be read again, off the main thread: a copy
    /// of a floppy, or a hard disc's file.
    enum ExportSource: Sendable {
        case bytes([UInt8], sectorSize: Int, unreadable: [Range<Int>])
        case file(String, sectorSize: Int)

        func volume() throws -> ADFSVolume {
            switch self {
            case .bytes(let b, let s, let bad): try ADFSVolume(store: ADFSMemoryStore(bytes: b, sectorSize: s, unreadable: bad))
            case .file(let p, let s): try ADFSVolume(store: ADFSFileStore(path: p, sectorSize: s, writable: false))
            }
        }
    }

    private var reading = false
    private var readAgain = false
    /// What was last seen of the drives, to notice them change.
    private var seen: Signature?

    struct Signature: Equatable, Sendable {
        var floppy: ObjectIdentifier?
        var floppyWrites: Int
        var hardWrites: [UInt64]
    }

    /// Runs `body` on the emulation thread.
    private func onEmulation<T: Sendable>(_ body: @escaping @Sendable (EmulatorHost.Session) -> T) async -> T? {
        guard let host = machine.host else { return nil }
        return await withCheckedContinuation { c in host.send { c.resume(returning: body($0)) } }
    }

    private func signature() async -> Signature? {
        await onEmulation { s in
            let image = s.machine.fdc.drives[0].disc
            return Signature(floppy: image.map(ObjectIdentifier.init), floppyWrites: image?.writeCount ?? 0,
                             hardWrites: s.machine.hardDiscImages.map { $0?.writeCount ?? 0 })
        }
    }

    /// Reads the disc again if a drive has been written to (by RISC OS or
    /// anything else) since it was last read.
    func refreshIfChanged() async {
        guard !reading, !waiting, let now = await signature(), now != seen else { return }
        reload()
    }

    /// Reads the shown drive's disc again (coalescing a burst of requests).
    func reload() {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let drive = drive
        let hardDiscs = machine.hardDiscs
        let sectorSize = machine.model.hardDiscSectorSize
        Task {
            seen = await signature()
            var result: Result<ExportSource, Error>?
            switch drive {
            case .floppy:
                // Sector by sector: a copy protected disc's odd sectors stay
                // unreadable, and the rest can still be shown.
                let read: ExportSource?? = await onEmulation { s in
                    guard let image = s.machine.fdc.drives[0].disc else { return nil }
                    let store = ADFSFloppyStore(image: image)
                    let bad = store.unreadableAreas()
                    var bytes = [UInt8](repeating: 0, count: store.size)
                    for n in 0..<(store.size / store.sectorSize) where !bad.contains(where: { $0.contains(n * store.sectorSize) }) {
                        if let d = try? store.read(n * store.sectorSize, store.sectorSize) { bytes.replaceSubrange((n * store.sectorSize)..<((n + 1) * store.sectorSize), with: d) }
                    }
                    return .bytes(bytes, sectorSize: store.sectorSize, unreadable: bad)
                }
                if let read = read ?? nil { result = .success(read) }
            case .hard(let slot):
                if hardDiscs.indices.contains(slot), let p = hardDiscs[slot] { result = .success(.file(p, sectorSize: sectorSize)) }
            }
            apply(result)
            reading = false
            if readAgain {
                readAgain = false
                reload()
            }
        }
    }

    private func apply(_ result: Result<ExportSource, Error>?) {
        if !drives.contains(drive) { drive = .floppy }
        switch result {
        case nil:
            volume = nil
            source = nil
            problem = drive == .floppy ? "There’s no disc in drive :0." : "There’s no hard disc in drive :\(drive.number)."
        case .failure(let error):
            volume = nil
            source = nil
            problem = Self.describe(error)
        case .success(let s):
            do {
                volume = try s.volume()
                source = s
                problem = nil
            } catch {
                volume = nil
                source = nil
                problem = Self.describe(error)
            }
        }
        refreshItems()
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case ADFSError.notADFS: "This disc isn’t an ADFS disc (D, E or F format), so its files can’t be shown. It may be a game with its own format."
        case ADFSError.unreadable: "This disc has sectors in a non-standard layout (copy protection, perhaps), so its files can’t be shown or changed here."
        default: (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func refreshItems() {
        guard let volume else {
            items = []
            return
        }
        // A directory that's gone (deleted in RISC OS) takes us back out.
        while true {
            do {
                items = try volume.entries(at: path)
                break
            } catch {
                if path.isEmpty {
                    items = []
                    problem = Self.describe(error)
                    break
                }
                path.removeLast()
            }
        }
        sortItems()
        selection.formIntersection(items.map(\.id))
    }

    private func sortItems() {
        items.sort { a, b in
            for d in sortOrder {
                let order: ComparisonResult = switch d.key {
                case "type": Self.typeName(a).localizedStandardCompare(Self.typeName(b))
                case "size": compare(a.isDirectory ? -1 : a.length, b.isDirectory ? -1 : b.length)
                case "date": compare(a.date ?? .distantPast, b.date ?? .distantPast)
                case "access": a.access.compare(b.access)
                default: a.name.localizedStandardCompare(b.name)
                }
                if order != .orderedSame { return d.ascending == (order == .orderedAscending) }
            }
            return false
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    nonisolated static func typeName(_ e: ADFSVolume.Entry) -> String {
        if e.isApplication { return "Application" }
        if e.isDirectory { return "Directory" }
        if let t = e.fileType { return RISCOSFileType.name(t) }
        return "Untyped"
    }

    func open(_ e: ADFSVolume.Entry) {
        guard e.isDirectory else { return }
        path.append(e.name)
        selection = []
        refreshItems()
    }

    func goUp(to depth: Int) {
        path.removeLast(path.count - depth)
        selection = []
        refreshItems()
    }

    // MARK: Changing

    private enum Outcome: Sendable {
        case changed(ADFSChange, disc: ObjectIdentifier)
        case busy
        case noDisc
        case failed(String)
    }

    /// Makes a change to the shown drive's disc. Undo puts back what it
    /// replaced, unless the disc has been written to since.
    func change(_ name: String, undoManager: UndoManager?, _ body: @escaping @Sendable (ADFSVolume) throws -> Void) {
        let drive = drive
        perform(name, on: drive, undoManager: undoManager) { store in try ADFSVolume.edit(store, body) }
    }

    /// Runs `edit` against the drive's disc, when it can be changed.
    private func perform(_ name: String, on drive: DiscDrive, expecting disc: ObjectIdentifier? = nil, undoManager: UndoManager?,
                         _ edit: @escaping @Sendable (ADFSStore) throws -> ADFSChange) {
        guard !waiting else { return }
        switch drive {
        case .floppy: changeFloppy(name, expecting: disc, undoManager: undoManager, edit)
        case .hard(let slot): changeHardDisc(name, slot: slot, undoManager: undoManager, edit)
        }
    }

    private func changeFloppy(_ name: String, expecting disc: ObjectIdentifier?, undoManager: UndoManager?,
                              _ edit: @escaping @Sendable (ADFSStore) throws -> ADFSChange) {
        Task {
            waiting = true
            defer { waiting = false }
            for _ in 0..<60 {
                let outcome: Outcome? = await onEmulation { s in
                    guard let image = s.machine.fdc.drives[0].disc else { return .noDisc }
                    if let disc, disc != ObjectIdentifier(image) { return .failed("The disc in the drive has been changed since, so that can’t be undone.") }
                    guard s.machine.floppyIsIdle() else { return .busy }
                    do {
                        let change = try edit(ADFSFloppyStore(image: image))
                        s.machine.noteFloppyChanged()
                        return .changed(change, disc: ObjectIdentifier(image))
                    } catch {
                        return .failed(DiscContentsModel.describe(error))
                    }
                }
                switch outcome {
                case .changed(let change, let id)?:
                    registerUndo(name, change: change, drive: .floppy, disc: id, undoManager: undoManager)
                    reload()
                    return
                case .busy?:
                    try? await Task.sleep(for: .milliseconds(250))
                case .failed(let message)?:
                    alert = message
                    reload()
                    return
                case .noDisc?, nil:
                    reload()
                    return
                }
            }
            alert = "The floppy drive is still in use, so the disc can’t be changed. Try again when RISC OS has finished with it."
                + (machine.paused ? ", with the machine running again." : ".")
        }
    }

    private static let restartKey = "MacArchDiscContentsRestartOK"

    private func changeHardDisc(_ name: String, slot: Int, undoManager: UndoManager?,
                                _ edit: @escaping @Sendable (ADFSStore) throws -> ADFSChange) {
        guard machine.hardDiscs.indices.contains(slot), let path = machine.hardDiscs[slot] else { return }
        if !AppSettings.store.bool(forKey: Self.restartKey) {
            let a = NSAlert()
            a.messageText = "Changing a hard disc restarts the Archimedes"
            a.informativeText = "RISC OS keeps a hard disc’s map in memory, so it has to start again to see the change. Anything unsaved in the machine will be lost."
            a.addButton(withTitle: "Change and Restart")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on { AppSettings.store.set(true, forKey: Self.restartKey) }
        }
        let sectorSize = machine.model.hardDiscSectorSize
        Task {
            waiting = true
            defer { waiting = false }
            // Until RISC OS hasn't written to the drive for a couple of seconds.
            var last: UInt64?, still = 0
            for _ in 0..<60 where still < 8 {
                let count = await onEmulation { s in s.machine.hardDiscImages.indices.contains(slot) ? s.machine.hardDiscImages[slot]?.writeCount ?? 0 : 0 }
                still = count == last ? still + 1 : 0
                last = count
                if still < 8 { try? await Task.sleep(for: .milliseconds(250)) }
            }
            guard still >= 8 else {
                alert = "The hard disc is still in use, so it can’t be changed. Try again when RISC OS has finished with it."
                return
            }
            _ = await onEmulation { s in s.machine.hardDiscImages.forEach { $0?.synchronize(); $0?.suppressWrites = true } }
            let result = await Task.detached { () -> Result<ADFSChange, Error> in
                Result { try edit(ADFSFileStore(path: path, sectorSize: sectorSize, writable: true)) }
            }.value
            switch result {
            case .success(let change):
                registerUndo(name, change: change, drive: .hard(slot), disc: nil, undoManager: undoManager)
                machine.setHardware(hardDiscs: machine.hardDiscs, reload: true, keepingSession: machine.session != nil)
                reload()
            case .failure(let error):
                _ = await onEmulation { s in s.machine.hardDiscImages.forEach { $0?.suppressWrites = false } }
                alert = Self.describe(error)
            }
        }
    }

    private func registerUndo(_ name: String, change: ADFSChange, drive: DiscDrive, disc: ObjectIdentifier?, undoManager: UndoManager?) {
        guard let undoManager, !change.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.perform(name, on: drive, expecting: disc, undoManager: undoManager) { store in try change.revert(on: store) }
            }
        }
        undoManager.setActionName(name)
    }

    func setDiscName(_ name: String, undoManager: UndoManager?) {
        guard name != discName, !name.isEmpty else { return }
        change("Rename Disc", undoManager: undoManager) { try $0.setDiscName(name) }
    }

    func setBootOption(_ option: Int, undoManager: UndoManager?) {
        guard option != bootOption else { return }
        change("Change Boot Option", undoManager: undoManager) { $0.setBootOption(option) }
    }

    func delete(_ entries: [ADFSVolume.Entry], undoManager: UndoManager?) {
        guard !entries.isEmpty else { return }
        let path = path, names = entries.map(\.name)
        change(names.count == 1 ? "Delete “\(names[0])”" : "Delete \(names.count) Items", undoManager: undoManager) { v in
            for n in names { try v.delete(n, at: path, recursive: true) }
        }
    }

    func update(_ e: ADFSVolume.Entry, name: String, load: UInt32, exec: UInt32, attributes: UInt8, undoManager: UndoManager?) {
        let path = path
        change("Change “\(e.name)”", undoManager: undoManager) { v in
            try v.setInfo(e.name, at: path, load: e.isDirectory ? nil : load, exec: e.isDirectory ? nil : exec, attributes: attributes)
            if name != e.name { try v.rename(e.name, at: path, to: name) }
        }
    }

    func makeDirectory(_ name: String, undoManager: UndoManager?) {
        let path = path
        change("New Directory", undoManager: undoManager) { try $0.makeDirectory(name, at: path) }
    }

    /// Copies Mac files and folders onto the disc, into `directory` within
    /// the one shown (or the one shown).
    func add(_ urls: [URL], into directory: String? = nil, undoManager: UndoManager?) {
        let incoming: [ADFSHostFile]
        do {
            incoming = try urls.compactMap { try ADFSHostFile.read($0) }
        } catch {
            alert = error.localizedDescription
            return
        }
        guard !incoming.isEmpty else { return }
        let path = path + (directory.map { [$0] } ?? [])
        let count = incoming.reduce(0) { $0 + $1.fileCount }
        let name = incoming.count == 1 ? "Add “\(incoming[0].name)”" : "Add \(count) Files"
        change(name, undoManager: undoManager) { v in
            for f in incoming { try f.add(to: v, at: path) }
        }
    }

    // MARK: Taking files out

    func isBASIC(_ e: ADFSVolume.Entry) -> Bool { e.fileType == 0xFFB }

    /// Saves a BASIC program as text, where the user says.
    func exportAsText(_ e: ADFSVolume.Entry) {
        guard let volume, let data = try? volume.contents(of: e.name, at: path) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(e.name.map { $0 == "/" ? "." : $0 }) + ".bas"
        panel.allowedContentTypes = [UTType(filenameExtension: "bas", conformingTo: .plainText) ?? .plainText]
        panel.message = "The program listed as text, as LIST shows it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(BBCBasic.list(data).utf8).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Writes entries into `folder`: files named with their RISC OS types
    /// (",xxx"), directories as folders. Says which files couldn't be read.
    func export(_ entries: [ADFSVolume.Entry], to folder: URL) throws {
        guard let volume else { return }
        var skipped: [String] = []
        for e in entries { skipped += try ADFSExport.write(e, from: volume, at: path, to: folder.appendingPathComponent(ADFSExport.macName(e))) }
        if !skipped.isEmpty { showSkipped(skipped) }
    }

    func showSkipped(_ skipped: [String]) {
        alertTitle = "Some files couldn’t be copied"
        alert = Self.skippedMessage(skipped)
    }

    nonisolated static func skippedMessage(_ skipped: [String]) -> String {
        let list = skipped.prefix(8).joined(separator: "\n") + (skipped.count > 8 ? "\n…and \(skipped.count - 8) more" : "")
        return "These files are on sectors that aren't standard ADFS ones (the disc may be copy protected), so they were left out:\n\(list)"
    }
}

extension MachineController {
    /// Opens the Disc Contents window at `drive`.
    func showDiscContents(_ drive: DiscDrive) {
        discContentsDrive = drive
        discContentsRequested = true
    }
}
