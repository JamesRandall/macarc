import ArchimedesCore
import CGtk
import Foundation

// My Games: the user's own games, from disc images and cover pictures
// dragged in. (The Mac app's, with GDK reading the pictures.)

/// A game the user added themselves: a disc image, a cover, or both, and
/// how to play it.
struct PersonalGame: Codable, Sendable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    var publisher: String?
    var year: Int?
    var notes: String?
    /// The machine it plays on: a model, its memory, and its RISC OS (by
    /// version, e.g. "RISC OS 2"; nil for the ROM chosen in Settings).
    var model: MachineModel
    var ramKB: Int?
    var rom: String?
    var start: StartMethod
    /// In the game's folder.
    var discFile: String?
    var discSHA256: String?
    var coverFile: String?
    var added: Date

    init(id: UUID = UUID(), title: String, publisher: String? = nil, year: Int? = nil, notes: String? = nil,
         model: MachineModel = .a3000, ramKB: Int? = nil, rom: String? = nil, start: StartMethod = .insertOnly, added: Date = Date()) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.year = year
        self.notes = notes
        self.model = model
        self.ramKB = ramKB
        self.rom = rom
        self.start = start
        self.added = added
    }

    /// "Acorn A3000, 2 MB, RISC OS 2".
    var machineSummary: String {
        var parts = [model.displayName]
        if let ramKB { parts.append(ramKB >= 1024 ? "\(ramKB / 1024) MB" : "\(ramKB) KB") }
        if let rom { parts.append(rom) }
        return parts.joined(separator: ", ")
    }
}

/// How a game's started once its disc is in.
enum StartMethod: Codable, Sendable, Equatable, Hashable {
    /// The disc's !Boot, run at the desktop's command line.
    case boot
    /// An application on the disc (e.g. "!Lemmings"), started as a
    /// double-click in the Filer would.
    case application(String)
    /// At the desktop, F12 and a command, e.g. *Run ADFS::0.$.!Game.
    case type(String)
    /// Puts the disc in and leaves the rest to the player (double-click
    /// the drive icon, then the game).
    case insertOnly
}

enum MyGamesError: LocalizedError, Equatable {
    case notADisc(String)
    case notAnImage(String)
    case tooLarge(String)
    case unreadable(String, String)
    case notFound
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADisc(let name): "“\(name)” isn’t a floppy disc image LinuxArch can read."
        case .notAnImage(let name): "“\(name)” isn’t a picture LinuxArch can show."
        case .tooLarge(let name): "“\(name)” is too large."
        case .unreadable(let name, let why): "“\(name)” can’t be read: \(why)"
        case .notFound: "The game isn’t in My Games any more."
        case .writeFailed(let why): "LinuxArch couldn’t save the game: \(why)"
        }
    }
}

/// A disc image the user's adding, read and checked.
struct DiscFile: Sendable, Equatable {
    var url: URL
    var data: Data
    var digest: String

    var fileName: String { url.lastPathComponent }

    /// A title from the file's name: "Zarch_(1987)(Superior_Software).adf" is
    /// "Zarch".
    var suggestedTitle: String {
        var name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        // "(1987)(Superior Software)" and "[a]": the archive's tags.
        if let range = name.range(of: #"\s*[\(\[].*$"#, options: .regularExpression) { name.removeSubrange(range) }
        if name.lowercased().hasPrefix("adfs ") { name.removeFirst(5) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The applications in the disc's root directory (!Lemmings), where
    /// it's an ADFS image LinuxArch can list.
    var applications: [String] { MyGames.applications(onDisc: [UInt8](data)) }

    /// How it's likeliest to start: its one application (leaving out read
    /// mes and the like), else its !Boot, else just put in.
    var suggestedStart: StartMethod {
        let notes = ["read", "help", "info", "doc", "manual", "instruct"]
        let apps = applications.filter { app in !notes.contains { app.lowercased().contains($0) } }
        if apps.count == 1 { return .application(apps[0]) }
        if MyGames.hasBoot([UInt8](data)) { return .boot }
        return .insertOnly
    }

    /// The year in its name, if it has one: "(1987)".
    var suggestedYear: Int? {
        guard let range = fileName.range(of: #"\((19[89]\d|20[0-2]\d)\)"#, options: .regularExpression) else { return nil }
        return Int(fileName[range].dropFirst().dropLast())
    }
}

/// The user's own games, in ~/.local/share/linuxarch/Library/MyGames:
///
///     mygames.json         the index
///     <id>/disc.adf        the game's disc (a copy: played from, never the original)
///     <id>/cover-….jpg     its cover
actor MyGames {
    nonisolated let root: URL
    private var index: Index
    private let fileManager = FileManager.default

    static let maxDiscSize: Int64 = 8 << 20
    static let maxCoverSize: Int64 = 32 << 20
    static let discExtensions: Set<String> = ["adf", "adl", "jfd", "hfe"]
    static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "webp", "bmp"]

    struct Index: Codable {
        var version = 1
        var games: [PersonalGame] = []
    }

    init(root: URL) {
        self.root = root
        index = (try? JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("mygames.json")))) ?? Index()
    }

    static var defaultRoot: URL {
        URL(fileURLWithPath: AppSettings.supportDirectory).appendingPathComponent("Library/MyGames", isDirectory: true)
    }

    /// In the order they were added.
    var games: [PersonalGame] { index.games }

    func game(id: UUID) -> PersonalGame? { index.games.first { $0.id == id } }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    nonisolated func discURL(_ game: PersonalGame) -> URL? {
        game.discFile.map { root.appendingPathComponent(game.id.uuidString).appendingPathComponent($0) }
    }

    nonisolated func coverURL(_ game: PersonalGame) -> URL? {
        game.coverFile.map { root.appendingPathComponent(game.id.uuidString).appendingPathComponent($0) }
    }

    // MARK: Checking files

    nonisolated static func isDiscName(_ url: URL) -> Bool { discExtensions.contains(url.pathExtension.lowercased()) }
    nonisolated static func isCoverName(_ url: URL) -> Bool { coverExtensions.contains(url.pathExtension.lowercased()) }

    /// Reads a floppy image of a kind LinuxArch plays (ADFS, JFD or HFE).
    nonisolated static func readDisc(at url: URL) throws -> DiscFile {
        let name = url.lastPathComponent
        guard isDiscName(url) else { throw MyGamesError.notADisc(name) }
        let data = try read(url, limit: maxDiscSize)
        guard (try? FloppyImage.open(path: url.path)) != nil else { throw MyGamesError.notADisc(name) }
        return DiscFile(url: url, data: data, digest: sha256(data))
    }

    /// Checks a picture can be shown.
    nonisolated static func checkCover(at url: URL) throws -> Data {
        let name = url.lastPathComponent
        guard isCoverName(url) else { throw MyGamesError.notAnImage(name) }
        let data = try read(url, limit: maxCoverSize)
        // GDK's loaders read it (as the shelf will show it).
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        guard let texture = gdk_texture_new_from_bytes(bytes, nil) else { throw MyGamesError.notAnImage(name) }
        g_object_unref(texture.raw)
        return data
    }

    private nonisolated static func read(_ url: URL, limit: Int64) throws -> Data {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw MyGamesError.unreadable(name, "it isn’t a file.") }
        guard Int64(values?.fileSize ?? 0) <= limit else { throw MyGamesError.tooLarge(name) }
        do { return try Data(contentsOf: url) } catch { throw MyGamesError.unreadable(name, error.localizedDescription) }
    }

    /// An ADFS image's root applications (directories named !…).
    nonisolated static func applications(onDisc bytes: [UInt8]) -> [String] {
        guard let disc = try? ADFSDiscReader.read(bytes: bytes) else { return [] }
        let roots = disc.items.filter { $0.path.count >= 2 }.map(\.path[0]) + disc.directories.filter { $0.count == 1 }.map(\.[0])
        return Array(Set(roots.filter { $0.hasPrefix("!") && $0.lowercased() != "!boot" && $0.lowercased() != "!system" }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Whether an ADFS image has a !Boot file in its root.
    nonisolated static func hasBoot(_ bytes: [UInt8]) -> Bool {
        guard let disc = try? ADFSDiscReader.read(bytes: bytes) else { return false }
        return disc.items.contains { $0.path.count == 1 && $0.path[0].lowercased() == "!boot" }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hex([UInt8](data))
    }

    /// Groups dropped files into games: each disc image is a game, with the
    /// picture of the same name (zarch.adf and zarch.jpg) as its cover, or
    /// the only picture if there's one disc and one picture. Pictures left
    /// over are games without discs, for now.
    nonisolated static func group(_ urls: [URL]) -> [(disc: URL?, cover: URL?)] {
        let discs = urls.filter(isDiscName)
        var covers = urls.filter(isCoverName)
        if discs.count == 1 && covers.count == 1 { return [(discs[0], covers[0])] }
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        var result: [(disc: URL?, cover: URL?)] = []
        for disc in discs {
            let cover = covers.firstIndex { stem($0) == stem(disc) }.map { covers.remove(at: $0) }
            result.append((disc, cover))
        }
        return result + covers.map { (nil, $0) }
    }

    // MARK: Changing

    /// Adds a game, copying in its disc and cover (either may come later).
    @discardableResult
    func add(_ game: PersonalGame, disc: DiscFile?, cover: URL?) throws -> PersonalGame {
        var game = game
        do {
            try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
            if let disc { try copyDisc(disc, into: &game) }
            if let cover { try copyCover(cover, into: &game) }
        } catch let error as MyGamesError {
            try? fileManager.removeItem(at: folder(game.id))
            throw error
        } catch {
            try? fileManager.removeItem(at: folder(game.id))
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        index.games.removeAll { $0.id == game.id }
        index.games.append(game)
        try save()
        return game
    }

    /// Changes a game's details (not its files).
    func update(_ changed: PersonalGame) throws {
        guard let i = index.games.firstIndex(where: { $0.id == changed.id }) else { throw MyGamesError.notFound }
        var game = changed
        game.discFile = index.games[i].discFile
        game.discSHA256 = index.games[i].discSHA256
        game.coverFile = index.games[i].coverFile
        index.games[i] = game
        try save()
    }

    /// Gives a game a disc, or a new one.
    @discardableResult
    func setDisc(_ disc: DiscFile, for id: UUID) throws -> PersonalGame {
        guard let i = index.games.firstIndex(where: { $0.id == id }) else { throw MyGamesError.notFound }
        var game = index.games[i]
        let old = discURL(game)
        do { try copyDisc(disc, into: &game) } catch let error as MyGamesError { throw error } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        if let old, old != discURL(game) { try? fileManager.removeItem(at: old) }
        index.games[i] = game
        try save()
        return game
    }

    /// Gives a game a cover, or a new one.
    @discardableResult
    func setCover(_ url: URL, for id: UUID) throws -> PersonalGame {
        guard let i = index.games.firstIndex(where: { $0.id == id }) else { throw MyGamesError.notFound }
        var game = index.games[i]
        let old = coverURL(game)
        do { try copyCover(url, into: &game) } catch let error as MyGamesError { throw error } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        if let old, old != coverURL(game) { try? fileManager.removeItem(at: old) }
        index.games[i] = game
        try save()
        return game
    }

    /// Deletes a game and LinuxArch's copies of its files (never the originals).
    func remove(id: UUID) throws {
        index.games.removeAll { $0.id == id }
        try save()
        try? fileManager.removeItem(at: folder(id))
    }

    private func copyDisc(_ disc: DiscFile, into game: inout PersonalGame) throws {
        let name = "disc.\(disc.url.pathExtension.lowercased())"
        let url = folder(game.id).appendingPathComponent(name)
        try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
        try disc.data.write(to: url, options: .atomic)
        guard (try? Self.sha256(Data(contentsOf: url))) == disc.digest else {
            throw MyGamesError.writeFailed("the copy of “\(disc.fileName)” didn’t match the original.")
        }
        game.discFile = name
        game.discSHA256 = disc.digest
    }

    private func copyCover(_ source: URL, into game: inout PersonalGame) throws {
        let data = try Self.checkCover(at: source)
        // A new name each time, so nothing shows a cached old cover.
        let name = "cover-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
        try data.write(to: folder(game.id).appendingPathComponent(name), options: .atomic)
        game.coverFile = name
    }

    private func save() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: root.appendingPathComponent("mygames.json"), options: .atomic)
        } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
    }
}
