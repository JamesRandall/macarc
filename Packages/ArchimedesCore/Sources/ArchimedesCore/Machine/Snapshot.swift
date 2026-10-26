import Foundation

/// Machine snapshots: a complete, versioned capture of emulated state.
///
/// Layout:
///   "MACARCHS"  u32 format version
///   u32 header length, header JSON (`SnapshotHeader`: configuration, ROM
///       SHA-256, guest time, media references)
///   u32 body length, u32 body CRC-32, u32 compressed length, zlib body
///
/// The body is a sequence of tagged sections (CPU, MEMC, IOC, ...), each
/// written by the component that owns the state. Restoring builds a fresh
/// machine, so a bad snapshot never leaves a half-loaded one behind.
/// Disc images are referenced by path and SHA-256, not embedded; their
/// copy-on-write overlays are embedded.
public enum SnapshotError: Error, CustomStringConvertible {
    case notASnapshot
    case unsupportedVersion(UInt32)
    case corrupt(String)
    case romMismatch(expected: String, actual: String)
    case mediaMissing(drive: Int, path: String?, sha256: String)

    public var description: String {
        switch self {
        case .notASnapshot: return "Not a MacArch snapshot file."
        case .unsupportedVersion(let v): return "Snapshot format version \(v) is not supported by this build (supports \(Snapshot.formatVersion))."
        case .corrupt(let s): return "Snapshot is corrupt: \(s)"
        case .romMismatch(let e, let a): return "Snapshot was taken with ROM \(e.prefix(16))…; the configured ROM is \(a.prefix(16))…"
        case .mediaMissing(let d, let p, let s): return "Snapshot needs the disc in drive \(d) (\(p ?? "unknown path"), sha256 \(s.prefix(16))…), which could not be found."
        }
    }
}

public struct SnapshotMedia: Codable, Sendable {
    public var drive: Int
    public var path: String?
    public var sha256: String
    public var format: String
}

public struct SnapshotHeader: Codable, Sendable {
    public var configuration: MachineConfiguration
    public var romSHA256: String
    public var romVersion: String
    public var guestTicks: UInt64
    public var frameCount: UInt64
    public var media: [SnapshotMedia]
    public var createdBy: String
    /// Hard discs are not captured: their paths and write counts are, so a
    /// restore can tell whether the disc has changed since.
    public var hardDiscs: [SnapshotHardDisc]?
    /// Optional extension: old snapshots had no per-drive change latch model.
    public var floppyDiscChanged: [Bool]? = nil
}

public struct SnapshotHardDisc: Codable, Sendable {
    public var unit: Int
    public var path: String
    public var writeCount: UInt64
}

public enum Snapshot {
    public static let magic = Array("MACARCHS".utf8)
    public static let formatVersion: UInt32 = 2
    /// Version 1 (before machine models) is read as an A3000 with ARM2.
    static let oldestReadable: UInt32 = 1

    /// Read just the header (for listing/validation without a ROM).
    public static func header(of data: [UInt8]) throws -> SnapshotHeader {
        var r = StateReader(data)
        return try readHeader(&r)
    }

    static func readHeader(_ r: inout StateReader) throws -> SnapshotHeader {
        guard r.remaining >= 12, (try? r.raw(8)) == magic else { throw SnapshotError.notASnapshot }
        let v = try r.u32()
        guard (oldestReadable...formatVersion).contains(v) else { throw SnapshotError.unsupportedVersion(v) }
        let json = try r.raw(Int(try r.u32()))
        do { return try JSONDecoder().decode(SnapshotHeader.self, from: Data(json)) } catch {
            throw SnapshotError.corrupt("header: \(error)")
        }
    }
}

// MARK: - Primitive coder

struct StateWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func i64(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
    mutating func double(_ v: Double) { u64(v.bitPattern) }
    mutating func raw(_ b: [UInt8]) { bytes += b }
    mutating func raw(_ p: UnsafePointer<UInt8>, count: Int) { bytes += UnsafeBufferPointer(start: p, count: count) }
    mutating func data(_ b: [UInt8]) { u32(UInt32(b.count)); bytes += b }
    mutating func string(_ s: String) { data(Array(s.utf8)) }
    mutating func optionalString(_ s: String?) { bool(s != nil); if let s { string(s) } }
    mutating func u32s(_ a: [UInt32]) { u32(UInt32(a.count)); for v in a { u32(v) } }
    mutating func u64s(_ a: [UInt64]) { u32(UInt32(a.count)); for v in a { u64(v) } }
    /// Section marker, checked on load to catch layout drift early.
    mutating func tag(_ t: String) { raw(Array(t.utf8.prefix(4)) + [UInt8](repeating: 0x20, count: max(0, 4 - t.utf8.count))) }
}

struct StateReader {
    let bytes: [UInt8]
    var p = 0
    init(_ b: [UInt8]) { bytes = b }

    var remaining: Int { bytes.count - p }

    mutating func need(_ n: Int) throws {
        guard n >= 0, p + n <= bytes.count else { throw SnapshotError.corrupt("truncated at byte \(p)") }
    }
    mutating func u8() throws -> UInt8 { try need(1); defer { p += 1 }; return bytes[p] }
    mutating func bool() throws -> Bool {
        let v = try u8()
        guard v <= 1 else { throw SnapshotError.corrupt("bad boolean at byte \(p - 1)") }
        return v == 1
    }
    mutating func u16() throws -> UInt16 { try need(2); defer { p += 2 }; return UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8 }
    mutating func u32() throws -> UInt32 {
        try need(4); defer { p += 4 }
        return UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
    }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) | UInt64(try u32()) << 32 }
    mutating func i64() throws -> Int { Int(Int64(bitPattern: try u64())) }
    mutating func double() throws -> Double { Double(bitPattern: try u64()) }
    mutating func raw(_ n: Int) throws -> [UInt8] { try need(n); defer { p += n }; return Array(bytes[p..<(p + n)]) }
    mutating func raw(into dst: UnsafeMutablePointer<UInt8>, count: Int) throws {
        try need(count)
        bytes.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress! + p, count: count) }
        p += count
    }
    mutating func data(max: Int = 64 << 20) throws -> [UInt8] {
        let n = Int(try u32())
        guard n <= max else { throw SnapshotError.corrupt("field of \(n) bytes at byte \(p)") }
        return try raw(n)
    }
    mutating func string() throws -> String { String(decoding: try data(max: 1 << 20), as: UTF8.self) }
    mutating func optionalString() throws -> String? { try bool() ? try string() : nil }
    mutating func u32s(count expected: Int? = nil) throws -> [UInt32] {
        let n = Int(try u32())
        if let expected, n != expected { throw SnapshotError.corrupt("expected \(expected) words, found \(n)") }
        try need(n * 4)
        return try (0..<n).map { _ in try u32() }
    }
    mutating func u64s(count expected: Int? = nil) throws -> [UInt64] {
        let n = Int(try u32())
        if let expected, n != expected { throw SnapshotError.corrupt("expected \(expected) values, found \(n)") }
        try need(n * 8)
        return try (0..<n).map { _ in try u64() }
    }
    mutating func tag(_ t: String) throws {
        let want = Array(t.utf8.prefix(4)) + [UInt8](repeating: 0x20, count: max(0, 4 - t.utf8.count))
        let got = try raw(4)
        guard got == want else { throw SnapshotError.corrupt("expected section \(t) at byte \(p - 4)") }
    }
}

// MARK: - Machine capture / restore

extension Machine {
    /// Capture the complete machine state.
    public func snapshot(createdBy: String = "MacArch", compressionLevel: Int32 = 6) -> [UInt8] {
        var body = StateWriter()
        body.tag("CPU"); cpu.saveState(&body)
        body.tag("MEMC"); memc.saveState(&body)
        body.tag("IOC"); ioc.saveState(&body)
        body.tag("KBD"); keyboard.saveState(&body)
        body.tag("RTC"); rtc.saveState(&body)
        body.tag("VIDC"); vidc.saveState(&body)
        body.tag("FDC"); fdc.saveState(&body)
        body.tag("SCHD"); scheduler.saveState(&body)
        body.tag("MACH"); saveMachineState(&body)
        if let hdc { body.tag("HDC"); hdc.saveState(&body) }
        if let superIO { body.tag("SIO"); superIO.saveState(&body) }
        body.tag("END")

        let media = fdc.drives.enumerated().compactMap { i, d in
            d.disc.map { SnapshotMedia(drive: i, path: $0.sourcePath, sha256: $0.sha256, format: $0.geometry.formatName) }
        }
        var header = SnapshotHeader(configuration: configuration, romSHA256: rom.sha256, romVersion: rom.versionString,
                                    guestTicks: ticks, frameCount: vidc.frameCount, media: media, createdBy: createdBy,
                                    hardDiscs: hardDiscRecords)
        header.floppyDiscChanged = fdc.discChangeState
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = [UInt8]((try? enc.encode(header)) ?? Data())

        var out = StateWriter()
        out.raw(Snapshot.magic)
        out.u32(Snapshot.formatVersion)
        out.data(json)
        out.u32(UInt32(body.bytes.count))
        out.u32(Self.crc32(body.bytes))
        out.data(Self.deflate(body.bytes, level: compressionLevel))
        return out.bytes
    }

    /// Uncompressed state sections keyed by tag (diagnostics: diffing two machines).
    public func stateSections() -> [(String, [UInt8])] {
        var out: [(String, [UInt8])] = []
        func add(_ t: String, _ f: (inout StateWriter) -> Void) { var w = StateWriter(); f(&w); out.append((t, w.bytes)) }
        add("CPU") { cpu.saveState(&$0) }
        add("MEMC") { memc.saveState(&$0) }
        add("IOC") { ioc.saveState(&$0) }
        add("KBD") { keyboard.saveState(&$0) }
        add("RTC") { rtc.saveState(&$0) }
        add("VIDC") { vidc.saveState(&$0) }
        add("FDC") { fdc.saveState(&$0) }
        add("SCHD") { scheduler.saveState(&$0) }
        add("MACH") { saveMachineState(&$0) }
        if let hdc { add("HDC") { hdc.saveState(&$0) } }
        if let superIO { add("SIO") { superIO.saveState(&$0) } }
        return out
    }

    /// Build a new machine from a snapshot. `rom` must match the snapshot's
    /// ROM; `resolveDisc` supplies the image for each referenced disc (by
    /// default, reopening its recorded path and checking the SHA-256).
    /// Hard discs are reattached, not restored: `hardDiscs` supplies the open
    /// images to reuse (by unit); otherwise each recorded path is reopened.
    public static func restore(snapshot data: [UInt8], rom: ROMImage,
                               resolveDisc: (SnapshotMedia) -> FloppyImage? = Machine.reopenDisc,
                               hardDiscs: [HardDiscImage?]? = nil) throws -> Machine {
        var r = StateReader(data)
        let header = try Snapshot.readHeader(&r)
        guard header.romSHA256 == rom.sha256 else { throw SnapshotError.romMismatch(expected: header.romSHA256, actual: rom.sha256) }
        let size = Int(try r.u32())
        let crc = try r.u32()
        let compressed = try r.data()
        guard size <= 64 << 20, let body = inflate(compressed, size: size), body.count == size else { throw SnapshotError.corrupt("body does not decompress") }
        guard crc32(body) == crc else { throw SnapshotError.corrupt("body checksum mismatch") }

        var discs: [Int: FloppyImage] = [:]
        for m in header.media {
            guard let img = resolveDisc(m), img.sha256 == m.sha256 else {
                throw SnapshotError.mediaMissing(drive: m.drive, path: m.path, sha256: m.sha256)
            }
            discs[m.drive] = img
        }

        var config = header.configuration
        config.cmosPath = nil // CMOS contents come from the snapshot
        let m = try Machine(configuration: config, rom: rom, hardDiscs: hardDiscs)
        for (d, img) in discs { m.fdc.drives[d].disc = img }
        var b = StateReader(body)
        try b.tag("CPU"); try m.cpu.loadState(&b)
        try b.tag("MEMC"); try m.memc.loadState(&b)
        try b.tag("IOC"); try m.ioc.loadState(&b)
        try b.tag("KBD"); try m.keyboard.loadState(&b)
        try b.tag("RTC"); try m.rtc.loadState(&b)
        try b.tag("VIDC"); try m.vidc.loadState(&b)
        try b.tag("FDC"); try m.fdc.loadState(&b)
        try b.tag("SCHD"); try m.scheduler.loadState(&b)
        try b.tag("MACH"); try m.loadMachineState(&b)
        if let hdc = m.hdc { try b.tag("HDC"); try hdc.loadState(&b) }
        if let sio = m.superIO { try b.tag("SIO"); try sio.loadState(&b) }
        try b.tag("END")
        guard b.remaining == 0 else { throw SnapshotError.corrupt("\(b.remaining) trailing bytes") }
        let changes = header.floppyDiscChanged ?? [Bool](repeating: false, count: 4)
        guard changes.count == 4 else { throw SnapshotError.corrupt("floppy change latch count") }
        m.fdc.restoreDiscChangeState(changes)
        m.deviceLog.append("restored snapshot at \(String(format: "%.3f", m.seconds)) s guest time")
        return m
    }

    var hardDiscRecords: [SnapshotHardDisc]? {
        guard configuration.model.hardDiscSlots > 0 else { return nil }
        return hardDiscImages.enumerated().compactMap { i, d in d.map { SnapshotHardDisc(unit: i + 1, path: $0.path, writeCount: $0.writeCount) } }
    }

    /// Default disc resolver: reopen the recorded path.
    public static func reopenDisc(_ media: SnapshotMedia) -> FloppyImage? {
        guard let p = media.path else { return nil }
        return try? FloppyImage.open(path: p)
    }

    // MARK: Compression helpers

    static func crc32(_ b: [UInt8]) -> UInt32 { Zlib.crc32(b) }

    static func deflate(_ b: [UInt8], level: Int32 = 6) -> [UInt8] { Zlib.compress(b, level: level) }

    static func inflate(_ b: [UInt8], size: Int) -> [UInt8]? { Zlib.uncompress(b, size: size) }
}
