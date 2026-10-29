import ArchimedesCore
import CGtk
import Foundation
import Observation

// The Archimedes Classics' discs: the Top 25's discs, downloaded by the
// user from the Archimedes Archive (arcarc.top) in their browser and
// recognised by their digests. (The Mac app's ClassicsLibrary, with GIO's
// folder monitor for the Downloads watcher, and LinuxBeeb's dialogs.)

extension ClassicsCatalogue {
    /// The installed (or, run from the source tree, the Mac app's) catalogue.
    @MainActor
    static let bundled: ClassicsCatalogue = {
        guard let url = AppPaths.resource("Classics/classics.json"), let data = try? Data(contentsOf: url) else {
            fatalError("LinuxArch: the classics catalogue (share/linuxarch/Classics/classics.json) is missing")
        }
        do {
            return try ClassicsCatalogue(data: data)
        } catch {
            fatalError("LinuxArch: the classics catalogue is unreadable: \(error)")
        }
    }()
}

/// A Classic's discs that are in the library: its files, by disc digest.
struct InstalledClassic: Codable, Sendable, Equatable {
    var gameID: String
    /// The library's copies, named as the archive names them.
    var files: [String: String]
    var importedAt: Date
}

/// A game whose archive page the user went to, to download it.
struct PendingDownload: Codable, Sendable, Equatable {
    var gameID: String
    var requestedAt: Date

    /// How long a pending download is waited for.
    static let lifetime: TimeInterval = 24 * 60 * 60
}

/// A file read and checked, ready to import.
struct DiscCandidate: Sendable, Equatable {
    var url: URL
    var digest: String
    var data: Data

    var fileName: String { url.lastPathComponent }
}

enum ClassicsImportError: LocalizedError {
    case unreadable(String, String)
    case tooLarge(String)
    case notThisGame(String, String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name, let why): "“\(name)” can’t be read: \(why)"
        case .tooLarge(let name): "“\(name)” is too large to be one of the Classics’ discs."
        case .notThisGame(let name, let game): "“\(name)” isn’t one of \(game)’s discs from the Archimedes Archive."
        case .writeFailed(let why): "LinuxArch couldn’t add the disc to its library: \(why)"
        }
    }
}

/// The Classics' discs, in ~/.local/share/linuxarch/Library/Classics:
///
///     library.json          the index
///     <game>/<file>         copies of the archive's files (never written:
///                           a floppy's changes stay in the machine)
///     <game>/harddisc.hdf   a hard disc built from a game's archive
///     <game>/cmos.bin       the game's CMOS while it's played
///
/// Originals (in Downloads, say) are only ever read.
actor ClassicsStore {
    nonisolated let root: URL
    let catalogue: ClassicsCatalogue
    private var index: Index
    private let fileManager = FileManager.default

    /// Larger files aren't considered (an HFE is 2 MB, Lemmings' ZIP 600K).
    static let maxFileSize: Int64 = 8 << 20
    static let extensions: Set<String> = ["adf", "adl", "hfe", "jfd", "zip"]

    struct Index: Codable {
        var version = 1
        var installed: [InstalledClassic] = []
        var pending: [PendingDownload] = []
        /// Digests of discs the user removed: watching Downloads won't add
        /// them back (adding them by hand will).
        var removedDigests: [String] = []
    }

    init(root: URL, catalogue: ClassicsCatalogue) {
        self.root = root
        self.catalogue = catalogue
        index = (try? JSONDecoder.classics.decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))) ?? Index()
    }

    static var defaultRoot: URL {
        URL(fileURLWithPath: AppSettings.supportDirectory).appendingPathComponent("Library/Classics", isDirectory: true)
    }

    nonisolated func folder(_ gameID: String) -> URL { root.appendingPathComponent(gameID, isDirectory: true) }

    var installed: [InstalledClassic] { index.installed }

    func pending(now: Date = Date()) -> [PendingDownload] {
        index.pending.filter { now.timeIntervalSince($0.requestedAt) < PendingDownload.lifetime }
    }

    func wasRemoved(digest: String) -> Bool { index.removedDigests.contains(digest) }

    func addPending(gameID: String) throws {
        index.pending.removeAll { $0.gameID == gameID }
        index.pending.append(PendingDownload(gameID: gameID, requestedAt: Date()))
        try save()
    }

    func cancelPending(gameID: String) throws {
        index.pending.removeAll { $0.gameID == gameID }
        try save()
    }

    /// Drops expired waits, and discs whose copies have gone.
    func reconcile() throws {
        var changed = false
        for i in index.installed.indices {
            let gone = index.installed[i].files.filter { !fileManager.fileExists(atPath: folder(index.installed[i].gameID).appendingPathComponent($0.value).path) }
            for key in gone.keys { index.installed[i].files[key] = nil; changed = true }
        }
        index.installed.removeAll { $0.files.isEmpty }
        let before = index.pending.count
        index.pending = pending()
        if changed || before != index.pending.count { try save() }
    }

    /// Reads a file that might be one of the Classics' discs.
    nonisolated static func candidate(at url: URL) throws -> DiscCandidate {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw ClassicsImportError.unreadable(name, "it isn’t a file.") }
        guard Int64(values?.fileSize ?? 0) <= maxFileSize else { throw ClassicsImportError.tooLarge(name) }
        do {
            let data = try Data(contentsOf: url, options: .uncached)
            return DiscCandidate(url: url, digest: SHA256.hex([UInt8](data)), data: data)
        } catch {
            throw ClassicsImportError.unreadable(name, error.localizedDescription)
        }
    }

    /// Copies a recognised disc into the library. Nil if it isn't one of
    /// the Classics' discs. A game's hard disc is built once its archive's in.
    func importCandidate(_ candidate: DiscCandidate) throws -> (game: ClassicGame, disc: Int)? {
        guard let (game, i) = catalogue.disc(forDigest: candidate.digest) else { return nil }
        let disc = game.discs[i]
        let destination = folder(game.id).appendingPathComponent(disc.fileName)
        do {
            try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
            try candidate.data.write(to: destination, options: .atomic)
            if disc.kind == .hardDiscArchive { try buildHardDisc(game, from: candidate.data) }
        } catch {
            throw ClassicsImportError.writeFailed(error.localizedDescription)
        }
        guard (try? SHA256.hex([UInt8](Data(contentsOf: destination)))) == candidate.digest else {
            try? fileManager.removeItem(at: destination)
            throw ClassicsImportError.writeFailed("the copy of “\(candidate.fileName)” didn’t match the original.")
        }
        if let n = index.installed.firstIndex(where: { $0.gameID == game.id }) {
            index.installed[n].files[disc.sha256] = disc.fileName
        } else {
            index.installed.append(InstalledClassic(gameID: game.id, files: [disc.sha256: disc.fileName], importedAt: Date()))
        }
        index.removedDigests.removeAll { $0 == candidate.digest }
        if hasAllDiscs(game) { index.pending.removeAll { $0.gameID == game.id } }
        try save()
        return (game, i)
    }

    /// The hard disc a game plays from: its archive's files on an IDE drive.
    nonisolated func hardDiscURL(_ game: ClassicGame) -> URL { folder(game.id).appendingPathComponent("harddisc.hdf") }

    private func buildHardDisc(_ game: ClassicGame, from zip: Data) throws {
        let items = try ADFSHardDiscBuilder.items(fromZip: [UInt8](zip))
        let url = hardDiscURL(game)
        try? fileManager.removeItem(at: url)
        try ADFSHardDiscBuilder.create(path: url.path, geometry: HardDiscGeometry(cylinders: 200, heads: 4, sectorsPerTrack: 17, sectorSize: 512),
                                       name: "HardDisc4", items: items)
    }

    func hasAllDiscs(_ game: ClassicGame) -> Bool {
        guard let record = index.installed.first(where: { $0.gameID == game.id }) else { return false }
        return game.discs.allSatisfy { record.files[$0.sha256] != nil }
    }

    /// Takes a game's discs out of the library (never the downloads).
    func remove(gameID: String) throws {
        guard let record = index.installed.first(where: { $0.gameID == gameID }) else { return }
        index.installed.removeAll { $0.gameID == gameID }
        for digest in record.files.keys where !index.removedDigests.contains(digest) { index.removedDigests.append(digest) }
        try save()
        try? fileManager.removeItem(at: folder(gameID))
    }

    private func save() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.classics.encode(index).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

extension JSONEncoder {
    static var classics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var classics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The Archimedes Classics shelf's state, shared by every window: which
/// games' discs are in, downloads being waited for, and the Downloads
/// watcher.
@MainActor
@Observable
final class ClassicsLibrary {
    static let shared = ClassicsLibrary()

    let catalogue = ClassicsCatalogue.bundled
    @ObservationIgnored let store: ClassicsStore

    /// Games with discs in, by game ID.
    private(set) var installed: [String: InstalledClassic] = [:]
    /// Games whose pages the user's been sent to, by game ID.
    private(set) var pending: [String: PendingDownload] = [:]
    /// Games a disc's being added to.
    private(set) var importing: Set<String> = []
    /// The game most recently completed, for a moment's confirmation.
    private(set) var justInstalled: String?
    /// Counts discs found in the watched folder: the Game Library comes to
    /// the front for each.
    private(set) var arrivals = 0

    // MARK: Settings

    private static let autoDetectKey = "classicsAutoDetect"
    private static let folderKey = "classicsDownloadFolder"
    /// Whether to watch for downloaded discs; nil until the user's been asked.
    var autoDetect: Bool? {
        didSet {
            if let autoDetect { Preferences.standard.set(autoDetect, forKey: Self.autoDetectKey) } else { Preferences.standard.removeObject(forKey: Self.autoDetectKey) }
            updateWatcher()
        }
    }

    /// The folder watched: Downloads unless the user chose another.
    var downloadFolder: URL {
        didSet {
            Preferences.standard.set(downloadFolder == Self.defaultDownloadFolder ? nil : downloadFolder.path, forKey: Self.folderKey)
            updateWatcher()
        }
    }

    /// The desktop's Downloads folder (named in the user's language).
    static var defaultDownloadFolder: URL {
        String(gBorrowed: g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD)).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    enum WatchState: Equatable {
        case off
        case watching
        /// The folder can't be read (it's gone, or not allowed).
        case noAccess(String)
    }

    private(set) var watchState = WatchState.off
    @ObservationIgnored private var watcher: DownloadsWatcher?

    private init() {
        store = ClassicsStore(root: ClassicsStore.defaultRoot, catalogue: ClassicsCatalogue.bundled)
        autoDetect = AppSettings.isSelfTest ? false : Preferences.standard.object(forKey: Self.autoDetectKey) as? Bool
        downloadFolder = Preferences.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) } ?? Self.defaultDownloadFolder
        Task {
            await refresh()
            updateWatcher()
        }
    }

    /// A window of the app's come to the front: look in Downloads again.
    func appBecameActive() {
        watcher?.scanSoon()
    }

    func refresh() async {
        try? await store.reconcile()
        installed = Dictionary(uniqueKeysWithValues: await store.installed.map { ($0.gameID, $0) })
        pending = Dictionary(uniqueKeysWithValues: await store.pending().map { ($0.gameID, $0) })
    }

    // MARK: States

    enum GameState: Equatable {
        case notInstalled
        case waiting
        case importing
        /// Some of its discs are in.
        case partial(have: Int, of: Int)
        case installed
    }

    func state(of game: ClassicGame) -> GameState {
        if importing.contains(game.id) { return .importing }
        let have = haveDiscs(game)
        if have == game.discs.count { return .installed }
        if pending[game.id] != nil { return .waiting }
        return have > 0 ? .partial(have: have, of: game.discs.count) : .notInstalled
    }

    func haveDiscs(_ game: ClassicGame) -> Int {
        guard let record = installed[game.id] else { return 0 }
        return game.discs.filter { record.files[$0.sha256] != nil }.count
    }

    func has(_ disc: ClassicDisc, of game: ClassicGame) -> Bool { installed[game.id]?.files[disc.sha256] != nil }

    /// The library's copy of each of the game's floppies, in order.
    func floppyURLs(_ game: ClassicGame) -> [URL] {
        guard let record = installed[game.id] else { return [] }
        return game.floppies.compactMap { record.files[$0.sha256].map { store.folder(game.id).appendingPathComponent($0) } }
    }

    // MARK: Getting games

    /// Sends the user to the game's folder in the archive, and waits for
    /// its discs.
    func get(_ game: ClassicGame) {
        Task {
            if autoDetect == nil { autoDetect = await Self.askToWatch() }
            try? await store.addPending(gameID: game.id)
            await refresh()
            watcher?.scanSoon()
        }
        openURI(game.archivePageURL.absoluteString, parent: frontWindow)
    }

    /// Downloads one of its discs, in the browser.
    func get(_ disc: ClassicDisc, of game: ClassicGame) {
        Task {
            if autoDetect == nil { autoDetect = await Self.askToWatch() }
            try? await store.addPending(gameID: game.id)
            await refresh()
        }
        openURI(disc.url.absoluteString, parent: frontWindow)
    }

    func cancelWaiting(_ game: ClassicGame) {
        Task {
            try? await store.cancelPending(gameID: game.id)
            await refresh()
        }
    }

    private static func askToWatch() async -> Bool {
        await Alerts.choice("Add downloaded discs automatically?",
                            "To add games automatically, allow LinuxArch to look for downloaded disc images in your Downloads folder. It only reads them, and only while LinuxArch is open. You can always add discs by hand, and change this in Preferences.",
                            responses: [("no", "Not Now"), ("yes", "Look for Downloads")], parent: frontWindow) == "yes"
    }

    /// Whether a file could be one of the Classics' discs, by its name.
    nonisolated static func isCandidateName(_ url: URL) -> Bool {
        ClassicsStore.extensions.contains(url.pathExtension.lowercased())
    }

    /// Adds files the user dropped or chose: those that are Classics' discs.
    /// Returns the ones that weren't.
    func add(_ urls: [URL]) async -> [URL] {
        var others: [URL] = []
        for url in urls {
            guard Self.isCandidateName(url),
                  let candidate = try? await Task.detached(operation: { try ClassicsStore.candidate(at: url) }).value,
                  catalogue.disc(forDigest: candidate.digest) != nil else {
                others.append(url)
                continue
            }
            await finishImport(candidate)
        }
        return others
    }

    /// Asks for a game's discs and adds them.
    func chooseAndImport(for game: ClassicGame, parent: Widget?) {
        FileDialogs.openMultiple(parent: parent, title: "\(game.title)’s Disc Images, as Downloaded from the Archimedes Archive") { urls in
            self.importDiscs(urls, for: game)
        }
    }

    private func importDiscs(_ urls: [URL], for game: ClassicGame) {
        Task {
            importing.insert(game.id)
            defer { importing.remove(game.id) }
            for url in urls {
                do {
                    let candidate = try await Task.detached { try ClassicsStore.candidate(at: url) }.value
                    guard catalogue.disc(forDigest: candidate.digest)?.game.id == game.id else {
                        throw ClassicsImportError.notThisGame(candidate.fileName, game.title)
                    }
                    await finishImport(candidate)
                } catch {
                    Alerts.show(error, parent: frontWindow)
                }
            }
        }
    }

    @discardableResult
    private func finishImport(_ candidate: DiscCandidate) async -> Bool {
        do {
            guard let (game, _) = try await store.importCandidate(candidate) else { return false }
            await refresh()
            arrivals += 1
            if state(of: game) == .installed { celebrate(game.id) }
            return true
        } catch {
            Alerts.show(error, parent: frontWindow)
            return false
        }
    }

    private func celebrate(_ gameID: String) {
        justInstalled = gameID
        Task {
            try? await Task.sleep(for: .seconds(4))
            if justInstalled == gameID { justInstalled = nil }
        }
    }

    /// Takes a game's discs out of the library, after asking.
    func remove(_ game: ClassicGame) {
        Task {
            guard await Alerts.confirm("Remove \(game.title) from the library?",
                                       "LinuxArch’s copies of its discs are deleted. Your downloads aren’t touched.",
                                       button: "Remove", destructive: true, parent: frontWindow) else { return }
            do { try await store.remove(gameID: game.id) } catch { Alerts.show(error, parent: frontWindow) }
            await refresh()
        }
    }

    func reveal(_ game: ClassicGame) {
        revealInFileManager(floppyURLs(game).first ?? store.folder(game.id), parent: frontWindow)
    }

    // MARK: Watching for downloads

    private func updateWatcher() {
        guard autoDetect == true else {
            watcher?.stop()
            watcher = nil
            watchState = .off
            return
        }
        if let watcher, watcher.folder == downloadFolder { return }
        watcher?.stop()
        let watcher = DownloadsWatcher(folder: downloadFolder) { [weak self] file in
            await self?.handleDownload(file) ?? true
        } onAccess: { [weak self] error in
            self?.watchState = error.map { .noAccess($0) } ?? .watching
        }
        self.watcher = watcher
        watcher.start()
    }

    /// A finished download: added if it's one of the Classics' discs.
    /// Returns whether it's been dealt with (false: look again when it
    /// changes).
    private func handleDownload(_ file: DownloadScanner.FileInfo) async -> Bool {
        guard let candidate = try? await Task.detached(operation: { try ClassicsStore.candidate(at: file.url) }).value else { return true }
        // Changed while being read: it'll settle and come round again.
        guard candidate.data.count == file.size else { return false }
        guard let (game, i) = catalogue.disc(forDigest: candidate.digest) else { return true }
        if installed[game.id]?.files[game.discs[i].sha256] != nil { return true }
        // Removed by the user: only a deliberate import brings it back.
        if await store.wasRemoved(digest: candidate.digest), pending[game.id] == nil { return true }
        importing.insert(game.id)
        defer { importing.remove(game.id) }
        await finishImport(candidate)
        return true
    }
}

/// Decides which files in a watched folder are finished downloads worth
/// looking at: plausible disc images whose size and date have held still
/// for a while. Each is offered once until it changes. (MacBeeb's.)
struct DownloadScanner {
    struct FileInfo: Sendable, Equatable {
        var url: URL
        var size: Int
        var modified: Date
        var isRegularFile: Bool

        var signature: Signature { Signature(size: size, modified: modified) }
    }

    struct Signature: Sendable, Equatable {
        var size: Int
        var modified: Date
    }

    var stabilityWindow: TimeInterval = 1.5
    private var settling: [String: (signature: Signature, since: Date)] = [:]
    private var offered: [String: Signature] = [:]
    static let memoryLimit = 2_000

    struct Result {
        var ready: [FileInfo]
        var settling: Bool
    }

    mutating func update(listing: [FileInfo], now: Date) -> Result {
        var ready: [FileInfo] = []
        var present = Set<String>()
        for file in listing where file.isRegularFile && file.size > 0 && Int64(file.size) <= ClassicsStore.maxFileSize {
            let key = file.url.standardizedFileURL.path
            present.insert(key)
            if offered[key] == file.signature { continue }
            if let seen = settling[key], seen.signature == file.signature {
                if now.timeIntervalSince(seen.since) >= stabilityWindow && now.timeIntervalSince(file.modified) >= stabilityWindow {
                    ready.append(file)
                }
            } else {
                settling[key] = (file.signature, now)
            }
        }
        settling = settling.filter { present.contains($0.key) }
        offered = offered.filter { present.contains($0.key) }
        for file in ready { settling[file.url.standardizedFileURL.path] = nil }
        return Result(ready: ready.sorted { $0.modified < $1.modified }, settling: !settling.isEmpty)
    }

    mutating func markHandled(_ file: FileInfo) {
        if offered.count >= Self.memoryLimit { offered.removeAll() }
        offered[file.url.standardizedFileURL.path] = file.signature
    }

    /// Lists `folder` (not its subfolders). Browsers' partial downloads
    /// (.download, .part, .crdownload) have their own extensions, so aren't
    /// candidates.
    static func list(_ folder: URL) throws -> [FileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants])
        return urls.compactMap { url in
            guard ClassicsLibrary.isCandidateName(url), let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return FileInfo(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast,
                            isRegularFile: values.isRegularFile == true && values.isSymbolicLink != true)
        }
    }
}

/// Watches one folder (not its subfolders) for finished downloads, while
/// it's wanted. Changes in the folder (GIO's monitor, from inotify), the app
/// coming to the front and starting up all just prompt another listing.
/// (LinuxBeeb's.)
@MainActor
final class DownloadsWatcher {
    let folder: URL
    private let handle: (DownloadScanner.FileInfo) async -> Bool
    private let onAccess: (String?) -> Void
    private var scanner = DownloadScanner()
    private var monitor: UnsafeMutablePointer<GFileMonitor>?
    private var scanning = false
    private var rescan = false
    private var scheduled: Task<Void, Never>?
    private var stopped = false

    init(folder: URL, handle: @escaping (DownloadScanner.FileInfo) async -> Bool, onAccess: @escaping (String?) -> Void) {
        self.folder = folder
        self.handle = handle
        self.onAccess = onAccess
    }

    func start() { scanSoon(after: 0) }

    func stop() {
        stopped = true
        scheduled?.cancel()
        if let monitor {
            g_file_monitor_cancel(monitor)
            g_object_unref(monitor.raw)
        }
        monitor = nil
    }

    func scanSoon(after delay: Double = 0.5) {
        guard !stopped else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.scan()
        }
    }

    private func scan() async {
        guard !stopped else { return }
        if scanning {
            rescan = true
            return
        }
        scanning = true
        defer {
            scanning = false
            if rescan {
                rescan = false
                scanSoon()
            }
        }
        let folder = self.folder
        let listing: [DownloadScanner.FileInfo]
        do {
            listing = try await Task.detached { try DownloadScanner.list(folder) }.value
        } catch {
            onAccess(Alerts.describe(error))
            return
        }
        onAccess(nil)
        startMonitor()
        let result = scanner.update(listing: listing, now: Date())
        for file in result.ready where !stopped {
            if await handle(file) { scanner.markHandled(file) }
        }
        if result.settling { scanSoon(after: scanner.stabilityWindow + 0.25) }
    }

    private func startMonitor() {
        guard monitor == nil, let file = g_file_new_for_path(folder.path) else { return }
        defer { g_object_unref(file.raw) }
        // G_FILE_MONITOR_WATCH_MOVES: a browser renames its partial file.
        guard let monitor = g_file_monitor_directory(file, GFileMonitorFlags(rawValue: 1 << 3), nil, nil) else { return }
        self.monitor = monitor
        // "changed" has the files and the event, which don't matter: any
        // change means look again.
        let callback: @convention(c) (gpointer?, gpointer?, gpointer?, Int32, gpointer?) -> Void = { _, _, _, _, data in
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scanSoon() }
        }
        la_signal_connect(monitor.raw, "changed", unsafeBitCast(callback, to: GCallback.self),
                          Unmanaged.passUnretained(self).toOpaque(), nil, 0)
    }
}
