import ArchimedesCore
import Foundation
import Observation

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
/// machine then restarts: RISC OS keeps a hard disc's map in memory. (The
/// Mac app's, with an undo stack of its own for changes that happen later.)
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

    enum SortKey: String, CaseIterable {
        case name, type, size, date, access
    }

    var sortKey = SortKey.name { didSet { sortItems() } }
    var sortAscending = true { didSet { sortItems() } }

    /// Undo and redo of the changes made here.
    let undo = UndoStack()

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
        let key = sortKey, ascending = sortAscending
        items.sort { a, b in
            var order: ComparisonResult = switch key {
            case .type: Self.typeName(a).localizedStandardCompare(Self.typeName(b))
            case .size: compare(a.isDirectory ? -1 : a.length, b.isDirectory ? -1 : b.length)
            case .date: compare(a.date ?? .distantPast, b.date ?? .distantPast)
            case .access: a.access.compare(b.access)
            case .name: .orderedSame
            }
            // Then by name.
            if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
            return order != .orderedSame && ascending == (order == .orderedAscending)
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
    func change(_ name: String, _ body: @escaping @Sendable (ADFSVolume) throws -> Void) {
        let drive = drive
        perform(name, on: drive, origin: .user) { store in try ADFSVolume.edit(store, body) }
    }

    /// Runs `edit` against the drive's disc, when it can be changed.
    private func perform(_ name: String, on drive: DiscDrive, expecting disc: ObjectIdentifier? = nil, origin: UndoStack.Origin,
                         _ edit: @escaping @Sendable (ADFSStore) throws -> ADFSChange) {
        guard !waiting else { return }
        switch drive {
        case .floppy: changeFloppy(name, expecting: disc, origin: origin, edit)
        case .hard(let slot): Task { await changeHardDisc(name, slot: slot, origin: origin, edit) }
        }
    }

    private func changeFloppy(_ name: String, expecting disc: ObjectIdentifier?, origin: UndoStack.Origin,
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
                    registerUndo(name, change: change, drive: .floppy, disc: id, origin: origin)
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

    private static let restartKey = "discContentsRestartOK"
    /// The window, for the question a hard disc change asks.
    @ObservationIgnored var parentWidget: Widget?

    /// Asks once (unless told not to again) whether to restart the machine
    /// for a hard disc change.
    private func confirmRestart() async -> Bool {
        if Preferences.standard.bool(forKey: Self.restartKey) { return true }
        var dontAsk = false
        let check = UI.check("Don’t ask again", active: false) { dontAsk = $0 }
        let ok: Bool = await withCheckedContinuation { continuation in
            var answered = false
            Alerts.askWithChild("Changing a hard disc restarts the Archimedes",
                                "RISC OS keeps a hard disc’s map in memory, so it has to start again to see the change. Anything unsaved in the machine will be lost.",
                                child: check, button: "Change and Restart", parent: parentWidget) {
                answered = true
                continuation.resume(returning: true)
            } cancelled: {
                if !answered { continuation.resume(returning: false) }
            }
        }
        if ok && dontAsk { Preferences.standard.set(true, forKey: Self.restartKey) }
        return ok
    }

    private func changeHardDisc(_ name: String, slot: Int, origin: UndoStack.Origin,
                                _ edit: @escaping @Sendable (ADFSStore) throws -> ADFSChange) async {
        guard machine.hardDiscs.indices.contains(slot), let path = machine.hardDiscs[slot] else { return }
        guard await confirmRestart() else { return }
        let sectorSize = machine.model.hardDiscSectorSize
        do {
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
                registerUndo(name, change: change, drive: .hard(slot), disc: nil, origin: origin)
                machine.setHardware(hardDiscs: machine.hardDiscs, reload: true, keepingSession: machine.session != nil)
                reload()
            case .failure(let error):
                _ = await onEmulation { s in s.machine.hardDiscImages.forEach { $0?.suppressWrites = false } }
                alert = Self.describe(error)
            }
        }
    }

    private func registerUndo(_ name: String, change: ADFSChange, drive: DiscDrive, disc: ObjectIdentifier?, origin: UndoStack.Origin) {
        guard !change.isEmpty else { return }
        undo.register(name, origin: origin) { [weak self] reverse in
            self?.perform(name, on: drive, expecting: disc, origin: reverse) { store in try change.revert(on: store) }
        }
    }

    func setDiscName(_ name: String) {
        guard name != discName, !name.isEmpty else { return }
        change("Rename Disc") { try $0.setDiscName(name) }
    }

    func setBootOption(_ option: Int) {
        guard option != bootOption else { return }
        change("Change Boot Option") { $0.setBootOption(option) }
    }

    func delete(_ entries: [ADFSVolume.Entry]) {
        guard !entries.isEmpty else { return }
        let path = path, names = entries.map(\.name)
        change(names.count == 1 ? "Delete “\(names[0])”" : "Delete \(names.count) Items") { v in
            for n in names { try v.delete(n, at: path, recursive: true) }
        }
    }

    func update(_ e: ADFSVolume.Entry, name: String, load: UInt32, exec: UInt32, attributes: UInt8) {
        let path = path
        change("Change “\(e.name)”") { v in
            try v.setInfo(e.name, at: path, load: e.isDirectory ? nil : load, exec: e.isDirectory ? nil : exec, attributes: attributes)
            if name != e.name { try v.rename(e.name, at: path, to: name) }
        }
    }

    func makeDirectory(_ name: String) {
        let path = path
        change("New Directory") { try $0.makeDirectory(name, at: path) }
    }

    /// Copies files and folders onto the disc, into `directory` within the
    /// one shown (or the one shown).
    func add(_ urls: [URL], into directory: String? = nil) {
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
        change(name) { v in
            for f in incoming { try f.add(to: v, at: path) }
        }
    }

    // MARK: Taking files out

    func isBASIC(_ e: ADFSVolume.Entry) -> Bool { e.fileType == 0xFFB }

    /// Saves a BASIC program as text (listed, as LIST shows it), where the
    /// user says.
    func exportAsText(_ e: ADFSVolume.Entry, parent: Widget?) {
        guard let volume, let data = try? volume.contents(of: e.name, at: path) else { return }
        FileDialogs.save(parent: parent, title: "Export as Text", name: String(e.name.map { $0 == "/" ? "." : $0 }) + ".bas",
                         filters: [.init(name: "BASIC programs as text", suffixes: ["bas"])]) { url in
            do {
                try Data(BBCBasic.list(data).utf8).write(to: url)
            } catch {
                Alerts.show(error, parent: parent)
            }
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

/// Undo and redo for changes that take effect later (they wait for a drive),
/// so each says whether it's undoing or redoing when it registers its own
/// reversal. (Foundation's UndoManager wants its changes to register while
/// it's undoing.) LinuxBeeb's.
@MainActor
@Observable
final class UndoStack {
    enum Origin {
        case user, undo, redo
    }

    struct Entry {
        var name: String
        /// Makes the reversal, registering its own as `Origin`.
        var reverse: @MainActor (Origin) -> Void
    }

    private(set) var undos: [Entry] = []
    private(set) var redos: [Entry] = []

    /// Registers how to reverse a change that's been made, which came from
    /// the user, or from undoing or redoing.
    func register(_ name: String, origin: Origin, _ reverse: @escaping @MainActor (Origin) -> Void) {
        let entry = Entry(name: name, reverse: reverse)
        switch origin {
        case .user:
            undos.append(entry)
            redos.removeAll()
        case .undo:
            redos.append(entry)
        case .redo:
            undos.append(entry)
        }
    }

    var undoName: String? { undos.last?.name }
    var redoName: String? { redos.last?.name }

    func undo() {
        undos.popLast()?.reverse(.undo)
    }

    func redo() {
        redos.popLast()?.reverse(.redo)
    }
}
