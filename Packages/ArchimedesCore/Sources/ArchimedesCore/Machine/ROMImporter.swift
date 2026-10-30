import Foundation

/// Finds RISC OS ROMs among files the user offers (single images, sets of
/// chip dumps, folders, ZIP archives of any of these), says what each one
/// is and how sure we are, and installs them as single images.
///
/// A ROM is accepted when, in some chip layout, its first word is the ARM
/// branch of the reset vector, an "Arthur" or "RISC OS" version string
/// reads correctly (with byte-wide chips in the wrong order its bytes come
/// out scrambled, so it also proves the layout), and the image is the size
/// that version shipped as: 512 KB for Arthur and RISC OS 2, 2 MB for
/// RISC OS 3. (Some dumps split RISC OS 3 into four consecutive 512 KB
/// files, and the first of them alone would otherwise pass.) Images whose SHA-256
/// is in `known` are reported as known-good dumps.
public enum ROMImporter {
    /// A file offered for scanning: where it came from (for messages) and
    /// which folder it sat in (chip sets are looked for within one folder).
    public struct Entry: Sendable {
        public var name: String
        public var folder: String
        public var data: [UInt8]
        public init(name: String, folder: String, data: [UInt8]) { self.name = name; self.folder = folder; self.data = data }
    }

    public struct Found: Sendable, Identifiable {
        public var rom: ROMImage
        /// Where it came from, e.g. "riscos311.zip: IC24.ROM–IC27.ROM".
        public var origin: String
        public var known: Known?
        public var id: String { rom.sha256 }
    }

    public struct Rejected: Sendable, Identifiable {
        public var name: String
        public var reason: String
        public var id: String { name }
        public init(name: String, reason: String) { self.name = name; self.reason = reason }
    }

    public struct Result: Sendable {
        public var found: [Found] = []
        public var rejected: [Rejected] = []
    }

    public struct Known: Sendable {
        public var title: String
        public var note: String
    }

    /// Dumps checked by hand against their machines (SHA-256 of the
    /// combined image, as MacArch stores it).
    public static let known: [String: Known] = [
        "e916a0b84a2c8d96d43731ec9a02c9dff31312c95bca725b2b60e7eb3bfe7384":
            Known(title: "RISC OS 3.11", note: "UK release, 29 Sep 1992 (2 MB)"),
        "b2658bb1d30ea0d5e322dca2895ec969d9a28695f96726da119e08fb3aa068d3":
            Known(title: "RISC OS 2.00", note: "UK release, 05 Oct 1988 (512 KB)"),
        "d83d2e8cbb6adb1c37883e194c527279b5233c5ce3b0c9c324f6f6ae91447f2d":
            Known(title: "ArcLibre 0.8", note: "Free ROM from RISC OS's public sources, 28 Oct 2026 (2 MB)"),
        "ee1c8f489ba8d3cc7e6964eee6acae9df41413b3607d4f6943a22fb1951a944c":
            Known(title: "ArcLibre 0.9", note: "Free ROM from RISC OS's public sources, 29 Oct 2026 (2 MB)"),
        "d50d370b3254e1a159c26b19e893f2b1b6d440fee0a4b80669739e5449ca062e":
            Known(title: "ArcLibre 0.9", note: "Free ROM from RISC OS's public sources, with DOSFS, Alarm and printing, 29 Oct 2026 (4 MB)"),
        "9e7aa465948c06802c24b46de00635214d6b410df9d788963bbfbf9ef07a4eb9":
            Known(title: "ArcLibre 0.9.1", note: "Free ROM from RISC OS's public sources, 30 Oct 2026 (2 MB)"),
        "2ae82b6d9342f20f4c400a97b5615332fb2d449ead9571566376c33169f016d6":
            Known(title: "ArcLibre 0.9.1", note: "Free ROM from RISC OS's public sources, with DOSFS, Alarm and printing, 30 Oct 2026 (4 MB)"),
    ]

    /// Sizes a whole OS ROM comes in: Arthur and RISC OS 2 512 KB, RISC OS 3
    /// 2 MB. The sockets are wired for 4 MB (MEMC's high ROM is 8 MB, but
    /// the ROMs only reach 4 MB of it), and people fill them: RISC OS 3.11
    /// with an extension ROM after it, or a bigger ArcLibre.
    static let imageSizes: Set<Int> = [512 << 10, 1 << 20, 2 << 20, 4 << 20]
    /// Chip sizes: four 8-bit chips (128 KB, 512 KB or 1 MB) or two 16-bit ones.
    static let chipSets: [(count: Int, size: Int)] = [(4, 128 << 10), (4, 512 << 10), (4, 1 << 20), (2, 256 << 10), (2, 1 << 20), (2, 2 << 20)]
    static let maxFileSize = 16 << 20

    // MARK: Gathering files

    /// Reads the files, folders and ZIP archives at `urls` (folders to a
    /// few levels; archives inside archives one level).
    public static func entries(from urls: [URL]) -> (entries: [Entry], rejected: [Rejected]) {
        var out: [Entry] = [], rejected: [Rejected] = []
        let fm = FileManager.default
        func add(file url: URL, folder: String, depth: Int) {
            let name = url.lastPathComponent
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
                  let d = fm.contents(atPath: url.path) else {
                rejected.append(Rejected(name: name, reason: "too large to be a ROM"))
                return
            }
            let bytes = [UInt8](d)
            if ZipArchive.isZip(bytes) {
                let (e, r) = entries(fromZip: bytes, name: name, depth: depth)
                out += e; rejected += r
            } else {
                out.append(Entry(name: name, folder: folder, data: bytes))
            }
        }
        func walk(_ url: URL, depth: Int) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                guard depth < 4, let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
                for n in names.sorted() where !n.hasPrefix(".") {
                    let child = url.appendingPathComponent(n)
                    var sub: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &sub)
                    if sub.boolValue { walk(child, depth: depth + 1) } else { add(file: child, folder: url.path, depth: 0) }
                }
            } else {
                add(file: url, folder: url.deletingLastPathComponent().path, depth: 0)
            }
        }
        for u in urls { walk(u, depth: 0) }
        return (out, rejected)
    }

    static func entries(fromZip bytes: [UInt8], name: String, depth: Int) -> ([Entry], [Rejected]) {
        let members: [ZipArchive.Member]
        do { members = try ZipArchive.read(bytes) } catch {
            return ([], [Rejected(name: name, reason: "can't be read as a ZIP archive: \(error)")])
        }
        var out: [Entry] = [], rejected: [Rejected] = []
        for m in members where !m.isDirectory {
            let leaf = (m.path as NSString).lastPathComponent
            if leaf.hasPrefix(".") || m.path.hasPrefix("__MACOSX/") { continue }
            let folder = name + ":" + (m.path as NSString).deletingLastPathComponent
            if ZipArchive.isZip(m.data) {
                if depth < 1 {
                    let (e, r) = entries(fromZip: m.data, name: name + ": " + m.path, depth: depth + 1)
                    out += e; rejected += r
                }
                continue
            }
            out.append(Entry(name: name + ": " + m.path, folder: folder, data: m.data))
        }
        return (out, rejected)
    }

    // MARK: Recognising

    public static func scan(urls: [URL]) -> Result {
        let (e, r) = entries(from: urls)
        var result = scan(e)
        result.rejected = r + result.rejected
        return result
    }

    public static func scan(_ entries: [Entry]) -> Result {
        var result = Result()
        var used = Set<Int>()
        var seen = Set<String>()
        func accept(_ rom: ROMImage, origin: String) {
            guard seen.insert(rom.sha256).inserted else { return }
            result.found.append(Found(rom: rom, origin: origin, known: known[rom.sha256]))
        }
        // Whole images first.
        for (i, e) in entries.enumerated() where imageSizes.contains(e.data.count) {
            if let rom = recognise([e.data], sources: [e.name]) { accept(rom, origin: e.name); used.insert(i) }
        }
        // Then chip sets: files of one chip size in one folder.
        let groups = Dictionary(grouping: entries.indices.filter { !used.contains($0) }) { "\(entries[$0].folder)\u{0}\(entries[$0].data.count)" }
        for key in groups.keys.sorted() {
            let members = groups[key]!.sorted { entries[$0].name.localizedStandardCompare(entries[$1].name) == .orderedAscending }
            let size = entries[members[0]].data.count
            guard let set = chipSets.first(where: { $0.size == size && members.count % $0.count == 0 }) else { continue }
            // Several sets in one folder: take them in name order.
            for start in stride(from: 0, to: members.count, by: set.count) {
                let chips = Array(members[start..<(start + set.count)])
                switch recogniseChips(chips.map { entries[$0].data }, names: chips.map { entries[$0].name }) {
                case .found(let rom):
                    accept(rom, origin: chipRange(chips.map { entries[$0].name }))
                    chips.forEach { used.insert($0) }
                case .unordered(let reason):
                    result.rejected.append(Rejected(name: chipRange(chips.map { entries[$0].name }), reason: reason))
                    chips.forEach { used.insert($0) }
                case .none:
                    break
                }
            }
        }
        for (i, e) in entries.enumerated() where !used.contains(i) {
            if let reason = rejection(e, among: entries) { result.rejected.append(Rejected(name: e.name, reason: reason)) }
        }
        result.found.sort { $0.rom.versionString > $1.rom.versionString }
        return result
    }

    /// A whole image in one file.
    static func recognise(_ parts: [[UInt8]], sources: [String]) -> ROMImage? {
        guard let rom = try? ROMImage.build(parts: parts, sources: sources), hasVersion(rom), fits(rom.data.count, rom.versionString) else { return nil }
        return rom
    }

    /// The size each version shipped as.
    static func expectedSize(_ version: String) -> Int { version.hasPrefix("RISC OS 3") || version.hasPrefix("ArcLibre") ? 2 << 20 : 512 << 10 }

    /// Whether an image is a whole ROM: the size its version shipped as,
    /// or a bigger one holding more after it (up to the sockets' 4 MB).
    static func fits(_ size: Int, _ version: String) -> Bool {
        imageSizes.contains(size) && size >= expectedSize(version)
    }

    /// A set of files: consecutive slices in name order, or chips side by
    /// side in name order and then every other order (only the right one
    /// reads the version string correctly).
    static func recogniseChips(_ chips: [[UInt8]], names: [String]) -> ChipResult {
        func check(_ combined: [UInt8], _ sources: [String], _ note: String) -> ROMImage? {
            guard ROMImage.looksLikeRISCOS(combined) else { return nil }
            let version = ROMImage.findVersion(combined)
            guard ROMImage.isOS(version), fits(combined.count, version) else { return nil }
            return ROMImage(data: combined, sha256: SHA256.hex(combined), versionString: version, sources: sources, layoutNote: note)
        }
        // Consecutive slices: the version string can't prove their order,
        // so name order is taken only when the first file holds the kernel
        // (its reset branch and version string); any other order only when
        // it gives a known dump.
        if ROMImage.looksLikeRISCOS(chips[0]), versionIn(chips[0]),
           let rom = check(chips.flatMap { $0 }, names, "\(chips.count) files in name order") { return .found(rom) }
        for order in permutations(Array(chips.indices)) {
            if let rom = check(interleave(order.map { chips[$0] }), order.map { names[$0] },
                               "\(chips.count) x \(chips.count == 4 ? 8 : 16)-bit chips interleaved") { return .found(rom) }
        }
        for order in permutations(Array(chips.indices)) {
            let combined = order.flatMap { chips[$0] }
            let sha = SHA256.hex(combined)
            if known[sha] != nil, let rom = check(combined, order.map { names[$0] }, "\(chips.count) files, reordered to match a known dump") {
                return .found(rom)
            }
        }
        if let first = chips.indices.first(where: { ROMImage.looksLikeRISCOS(chips[$0]) && versionIn(chips[$0]) }) {
            return .unordered("\(names[first]) starts \(ROMImage.findVersion(chips[first])), but the other files' order can't be told: name them so they sort in order (such as IC24–IC27) and add them again")
        }
        return .none
    }

    enum ChipResult { case found(ROMImage), unordered(String), none }

    static func versionIn(_ d: [UInt8]) -> Bool {
        ROMImage.isOS(ROMImage.findVersion(d))
    }

    /// Chips side by side on the 32-bit bus: four byte-wide or two halfword-wide.
    static func interleave(_ chips: [[UInt8]]) -> [UInt8] {
        let n = chips[0].count, k = chips.count, width = 4 / k
        var out = [UInt8](repeating: 0, count: n * k)
        for i in 0..<(n / width) {
            for c in 0..<k { for b in 0..<width { out[i * 4 + c * width + b] = chips[c][i * width + b] } }
        }
        return out
    }

    static func permutations(_ a: [Int]) -> [[Int]] {
        guard a.count > 1 else { return [a] }
        return a.indices.flatMap { i -> [[Int]] in
            var rest = a; let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }

    static func hasVersion(_ rom: ROMImage) -> Bool {
        ROMImage.isOS(rom.versionString)
    }

    static func chipRange(_ names: [String]) -> String {
        guard let first = names.first, let last = names.last, names.count > 1 else { return names.first ?? "" }
        return first + " – " + (last as NSString).lastPathComponent
    }

    /// Why a file was left out, or nil for files that obviously aren't
    /// ROMs (text, pictures) and are skipped quietly.
    static func rejection(_ e: Entry, among all: [Entry]) -> String? {
        let n = e.data.count
        if n < 64 << 10 { return nil }
        if imageSizes.contains(n), let rom = try? ROMImage.build(parts: [e.data], sources: [e.name]), hasVersion(rom), !fits(n, rom.versionString) {
            return "part of \(rom.versionString), which is \(expectedSize(rom.versionString) >> 20) MB: add all of its files together"
        }
        let partners = all.filter { $0.folder == e.folder && $0.data.count == n }.count
        if let set = chipSets.first(where: { $0.size == n }), partners % set.count != 0 {
            return "no RISC OS or Arthur version string in it; if it's one chip of a set of \(set.count), add the others with it (\(partners) found)"
        }
        if chipSets.contains(where: { $0.size == n }) { return "looks like a ROM chip, but no order of its set reads as RISC OS" }
        if imageSizes.contains(n) { return "the right size for a ROM, but no RISC OS or Arthur version string was found in it" }
        return "\(n / 1024) KB is not a RISC OS ROM size (512 KB, 2 MB or 4 MB, or chips of 128 KB, 512 KB or 1 MB)"
    }

    // MARK: Installing

    /// Models this ROM can drive.
    public static func models(for rom: ROMImage) -> [MachineModel] {
        models(version: rom.versionString, size: rom.data.count)
    }

    /// Models a ROM of this version and size can drive. The A5000 family's
    /// ADFS needs RISC OS 3, or ArcLibre 0.9 or later (0.8 had only the
    /// earlier machines' drivers). ArcLibre's 4 MB ROM is for the A5000
    /// family alone: the earlier machines' sockets take at most 2 MB.
    public static func models(version: String, size: Int) -> [MachineModel] {
        MachineModel.allCases.filter { whyNot(version: version, size: size, on: $0) == nil }
    }

    /// Why a ROM can't drive a model ("Not for the A3000: …"), or nil if it can.
    public static func whyNot(version: String, size: Int, on model: MachineModel) -> String? {
        if version.hasPrefix("ArcLibre") {
            let number = version.dropFirst("ArcLibre ".count).prefix { $0.isNumber || $0 == "." }
            if size > 2 << 20 && !model.hasNewIO { return "its ROM sockets take at most 2 MB; ArcLibre's 4 MB ROM is for the A5000 family" }
            if model.hasNewIO && (Double(number) ?? 0) < 0.9 { return "it needs RISC OS 3, or ArcLibre 0.9 or later" }
            return nil
        }
        if model.hasNewIO && !version.hasPrefix("RISC OS 3") { return "it needs RISC OS 3" }
        return nil
    }

    /// Writes the ROM as a single image in `directory` (named after its
    /// version) unless an image with the same contents is already there.
    /// Returns the image's path.
    @discardableResult
    public static func install(_ rom: ROMImage, into directory: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let existing = installedPath(sha256: rom.sha256, in: directory) { return existing }
        // A bigger image than its version shipped as is named with its size,
        // beside the usual one (ArcLibre's 4 MB ROM by its 2 MB one).
        var base = String(rom.versionString.map { "/:\\".contains($0) ? "-" : $0 })
        if rom.data.count > expectedSize(rom.versionString) { base += " \(rom.data.count >> 20) MB" }
        var path = (directory as NSString).appendingPathComponent(base + ".rom")
        if fm.fileExists(atPath: path) { path = (directory as NSString).appendingPathComponent("\(base) \(rom.sha256.prefix(8)).rom") }
        try HostFiles.write(Data(rom.data), to: path)
        return path
    }

    /// An image in `directory` with these contents, if any.
    public static func installedPath(sha256: String, in directory: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        for n in names where n.hasSuffix(".rom") {
            let p = (directory as NSString).appendingPathComponent(n)
            if let d = FileManager.default.contents(atPath: p), SHA256.hex([UInt8](d)) == sha256 { return p }
        }
        return nil
    }
}
