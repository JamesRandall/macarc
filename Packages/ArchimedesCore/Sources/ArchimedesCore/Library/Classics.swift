import Foundation

// The Archimedes Classics: a Top 25 of Archimedes games, each with the
// discs it comes on (from the Archimedes Archive, arcarc.top), the machine
// it plays on and how it's started, so playing one boots into the game.
// The catalogue is data (the app bundles classics.json); MacArch never
// downloads the discs itself. (After MacBeeb's BBC Micro Classics.)

public struct ClassicsCatalogue: Codable, Sendable {
    public var version: Int
    public var source: String
    public var archive: ClassicsArchive
    /// In rank order.
    public var games: [ClassicGame]

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ClassicsCatalogue.self, from: data)
        games.sort { $0.rank < $1.rank }
    }

    public func game(id: String) -> ClassicGame? { games.first { $0.id == id } }

    /// The game a disc (or archive) is, and which of its discs, by SHA-256
    /// (lowercase hex). Only the digest identifies a disc; names are hints.
    public func disc(forDigest digest: String) -> (game: ClassicGame, index: Int)? {
        let digest = digest.lowercased()
        for game in games {
            if let i = game.discs.firstIndex(where: { $0.sha256 == digest }) { return (game, i) }
        }
        return nil
    }
}

/// The archive the discs come from: the special book at the end of the shelf.
public struct ClassicsArchive: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let pitch: String
    public let about: String
    public let url: URL
}

public struct ClassicGame: Codable, Sendable, Identifiable, Hashable {
    /// Stable, and its cover's name: "zarch" (Covers/zarch.jpg).
    public let id: String
    public let rank: Int
    public let title: String
    public let editionLabel: String?
    public let publisher: String?
    public let year: Int?
    public let authors: String?
    public let description: String
    /// Something the player needs to know to get going (a code sheet, a
    /// click on the icon bar).
    public let hint: String?
    /// The game's folder in the archive, listing its files.
    public let archivePageURL: URL
    public let machine: ClassicMachine
    /// In the order they're asked for; the first goes in drive 0.
    public let discs: [ClassicDisc]
    public let start: ClassicStart
    /// It loads onto the icon bar and waits there: its icon's clicked.
    public let clickIconBar: Bool?

    /// The floppies (not a hard disc built from an archive).
    public var floppies: [ClassicDisc] { discs.filter { $0.kind == .floppy } }
}

public struct ClassicDisc: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A floppy image (ADFS, JFD or HFE).
        case floppy
        /// A ZIP of the game's files, which become a hard disc.
        case hardDiscArchive
    }

    /// "Disc 1", "Maps disc".
    public let label: String
    public let fileName: String
    public let url: URL
    public let sha256: String
    public let byteCount: Int
    public let kind: Kind
    /// The ADFS disc name, which the game's run by (so <Obey$Dir> stays
    /// with this disc when another goes in) and which prompts for it name.
    public let discName: String?

    enum CodingKeys: CodingKey { case label, fileName, url, sha256, byteCount, kind, discName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        fileName = try c.decode(String.self, forKey: .fileName)
        url = try c.decode(URL.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .floppy
        discName = try c.decodeIfPresent(String.self, forKey: .discName)
    }
}

/// The machine a game's set up as when it's played.
public struct ClassicMachine: Codable, Sendable, Hashable {
    public let model: MachineModel
    public let ramKB: Int
    /// RISC OS versions it runs on, best first: "RISC OS 3", "RISC OS 2".
    public let roms: [String]
    /// For people: "Acorn A3000, 2 MB, RISC OS 2 or 3".
    public let summary: String
}

/// How a game's started once the desktop's up.
public enum ClassicStart: Codable, Sendable, Hashable {
    /// An application, as a double-click in the Filer starts it. On a hard
    /// disc game it's on drive 4. `openDirectory` opens the disc's window
    /// first, so the Filer sees its !System.
    case run(application: String, openDirectory: Bool)
    /// Commands at the desktop's command line (F12), one per line.
    case command(String)

    enum CodingKeys: CodingKey { case run, openDirectory, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let app = try c.decodeIfPresent(String.self, forKey: .run) {
            self = .run(application: app, openDirectory: try c.decodeIfPresent(Bool.self, forKey: .openDirectory) ?? false)
        } else {
            self = .command(try c.decode(String.self, forKey: .command))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .run(let app, let open):
            try c.encode(app, forKey: .run)
            if open { try c.encode(true, forKey: .openDirectory) }
        case .command(let text):
            try c.encode(text, forKey: .command)
        }
    }
}

extension ClassicGame {
    /// What's typed at the command line (after F12) to start it: an empty
    /// line at the end takes the command line away again, back to the
    /// desktop, where a Filer_Run starts. RISC OS 2 has no Filer_Run, so
    /// there the application's run from the command line.
    public var commandLine: String { commandLine(riscOS2: false) }

    public func commandLine(riscOS2: Bool) -> String {
        switch start {
        case .command(let text):
            return text.hasSuffix("\n") ? text : text + "\n"
        case .run(let app, let open):
            let drive: String
            if discs.first?.kind == .hardDiscArchive {
                drive = "4"
            } else if floppies.count > 1, let name = floppies.first?.discName {
                // By name, as the Filer does, so <Obey$Dir> doesn't follow
                // drive 0 to the next disc.
                drive = name
            } else {
                drive = "0"
            }
            return (open ? "Filer_OpenDir ADFS::\(drive).$\n" : "") + (riscOS2 ? "Run" : "Filer_Run") + " ADFS::\(drive).$.\(app)\n\n"
        }
    }
}

/// Boots a Classic: waits for the desktop, types its start at the command
/// line, then watches for the game asking for another of its discs and puts
/// it in. It's stepped (on the machine's thread) every so often by whoever
/// runs the machine: the app, or a test.
public final class ClassicLauncher {
    public enum Event: Equatable, Sendable {
        /// The command's been typed.
        case started
        /// The game asked for disc `index`, and it's gone in.
        case inserted(index: Int)
        /// Its icon on the icon bar's been clicked.
        case clickedIconBar
    }

    public let game: ClassicGame
    /// The floppies, in the game's order (drive 0 has the first).
    private let floppies: [FloppyImage]
    public private(set) var currentDisc = 0
    public private(set) var started = false
    private var desktopAt: Double?
    private var textMark: UInt64
    /// Recent text the game has printed, to find prompts across steps.
    private var window = ""
    /// A swap under way: the disc ejected at `since`, to go in when `due`.
    private var swap: (index: Int, due: Double)?
    private let riscOS2: Bool
    /// Clicking the game's icon on the icon bar: waiting for it to appear,
    /// then steering the pointer to it.
    private enum Click { case waiting, steering, done }
    private var click: Click
    private var iconSince: Double?
    private var target = (x: 0, y: 0)
    private var quietSince: Double?

    /// The machine must have been made for the game, with the first
    /// floppy in (or the hard disc fitted).
    public init(game: ClassicGame, floppies: [FloppyImage], machine m: Machine) {
        self.game = game
        self.floppies = floppies
        textMark = m.textOutput.totalAppended
        riscOS2 = m.rom.versionString.hasPrefix("RISC OS 2") || m.rom.versionString.hasPrefix("Arthur")
        // (RISC OS 3's icon bar: RISC OS 2's lays out differently, and its
        // player is told to click.)
        click = game.clickIconBar == true && !riscOS2 ? .waiting : .done
    }

    /// Advances the launch; returns what happened, if anything.
    public func step(_ m: Machine) -> Event? {
        if !started { return startWhenReady(m) }
        if let swap {
            guard m.seconds >= swap.due else { return nil }
            m.insertFloppy(floppies[swap.index])
            currentDisc = swap.index
            self.swap = nil
            return .inserted(index: swap.index)
        }
        if click != .done, let event = clickIconBar(m) { return event }
        readNewText(m)
        guard floppies.count > 1, let wanted = Self.requestedDisc(in: window, discs: game.floppies),
              wanted != currentDisc, floppies.indices.contains(wanted) else { return nil }
        window = ""
        insert(wanted, m)
        return nil
    }

    /// Puts another of the game's discs in (out, a moment, then in, as a
    /// person would); `step` finishes it.
    public func insert(_ index: Int, _ m: Machine) {
        guard floppies.indices.contains(index) else { return }
        m.ejectFloppy()
        swap = (index, m.seconds + 1.0)
    }

    /// Where a newly loaded application's icon is on RISC OS 3's icon bar
    /// (in the desktop's default mode): the third icon from the right,
    /// after the Task Manager's and the palette's. Nil until it's there.
    static func newIconBarIcon(in f: VideoFrame) -> (x: Int, y: Int)? {
        // Inside the bar: below its top edge, above the icons' names.
        let band = 242...258
        guard f.width > 700, f.height > band.upperBound else { return nil }
        let background = f.pixels[241 * f.width + 400]
        // The bar's right-hand end.
        var x = 400
        while x < f.width - 1 && f.pixels[241 * f.width + x] == background { x += 1 }
        var runs: [ClosedRange<Int>] = []
        var runEnd: Int?, gap = 0
        x -= 2
        while x >= 200 && runs.count < 3 {
            if band.contains(where: { f.pixels[$0 * f.width + x] != background }) {
                runEnd = runEnd ?? x
                gap = 0
            } else if let end = runEnd {
                gap += 1
                if gap >= 4 { runs.append((x + gap)...end); runEnd = nil }
            }
            x -= 1
        }
        guard runs.count == 3, runs[2].count >= 8 else { return nil }
        return ((runs[2].lowerBound + runs[2].upperBound) / 2, 250)
    }

    private func clickIconBar(_ m: Machine) -> Event? {
        let f = m.currentFrame
        switch click {
        case .waiting:
            // Clicked once it's finished loading: the disc quiet a while
            // (or, for a game that keeps its drive going, after a while).
            guard let icon = Self.newIconBarIcon(in: f) else {
                iconSince = nil
                quietSince = nil
                return nil
            }
            target = icon
            iconSince = iconSince ?? m.seconds
            quietSince = m.discsBusy ? nil : quietSince ?? m.seconds
            if m.seconds - (quietSince ?? .infinity) >= 4 || m.seconds - iconSince! >= 20 { click = .steering }
            return nil
        case .steering:
            let p = m.vidc.pointerHotspot
            let ex = target.x - p.x, ey = target.y - p.y
            if abs(ex) <= 1 && abs(ey) <= 1 {
                let select = ArcKey.names["select"]!
                let now = m.memc.ticks
                m.schedule(Machine.InputEvent(tick: now, action: .keyDown(select)))
                m.schedule(Machine.InputEvent(tick: now + 24_000 * 80, action: .keyUp(select)))
                click = .done
                return .clickedIconBar
            }
            // About a count a pixel across; down, a count an OS unit.
            m.mouseMove(dx: max(-60, min(60, ex)), dy: max(-60, min(60, -ey * f.scaleY)))
            return nil
        case .done:
            return nil
        }
    }

    private func startWhenReady(_ m: Machine) -> Event? {
        if desktopAt == nil {
            readNewText(m)
            // RISC OS 3 puts its Apps icon on the icon bar last; RISC OS 2
            // has none, but labels the floppy ":0" (after its sprite, "D").
            // A slow start is given up waiting for after 60 seconds.
            let ready = riscOS2 ? window.contains("D:0") : window.contains("Apps")
            if ready || m.seconds > 60 { desktopAt = m.seconds }
            return nil
        }
        guard let at = desktopAt, m.seconds >= at + (riscOS2 ? 3 : 1) else { return nil }
        let f12: UInt8 = 0x0C
        let now = m.memc.ticks
        m.schedule(Machine.InputEvent(tick: now, action: .keyDown(f12)))
        m.schedule(Machine.InputEvent(tick: now + 24_000 * 120, action: .keyUp(f12)))
        m.scheduleTyping(game.commandLine(riscOS2: riscOS2), startingAt: now + 24_000 * 900, intervalMs: 50)
        started = true
        window = ""
        textMark = m.textOutput.totalAppended
        return .started
    }

    private func readNewText(_ m: Machine) {
        let total = m.textOutput.totalAppended
        let fresh = Int(min(total &- textMark, UInt64(m.textOutput.storage.count)))
        textMark = total
        guard fresh > 0 else { return }
        for b in m.textOutput.elements.suffix(fresh) {
            if b == 10 || b == 13 { window.append(" ") } else if b >= 32 && b < 127 { window.append(Character(UnicodeScalar(b))) }
        }
        if window.count > 400 { window = String(window.suffix(400)) }
    }

    /// Which disc text asks for, if it does: "Please insert Disk Two",
    /// "insert disc 2", or a disc's name ("Please insert disc 'Planets'").
    public static func requestedDisc(in text: String, discs: [ClassicDisc]) -> Int? {
        let lower = text.lowercased()
        guard let range = lower.range(of: #"insert\s+(the\s+)?(dis[ck])\b"#, options: .regularExpression) else { return nil }
        let rest = String(lower[range.upperBound...].prefix(40))
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                       "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8]
        let words = rest.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        if let first = words.first, let n = numbers[first], n <= discs.count { return n - 1 }
        for (i, disc) in discs.enumerated() {
            if let name = disc.discName?.lowercased(), words.prefix(3).contains(name) { return i }
        }
        return nil
    }
}
