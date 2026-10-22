import Foundation

/// Physical shape of a hard drive: ST506 drives under ADFS have 256-byte
/// sectors, IDE drives 512.
public struct HardDiscGeometry: Codable, Sendable, Equatable, Hashable {
    public var cylinders: Int
    public var heads: Int
    public var sectorsPerTrack: Int
    public var sectorSize: Int

    public init(cylinders: Int, heads: Int, sectorsPerTrack: Int = 32, sectorSize: Int = 256) {
        self.cylinders = cylinders; self.heads = heads; self.sectorsPerTrack = sectorsPerTrack; self.sectorSize = sectorSize
    }

    public var sectorCount: Int { cylinders * heads * sectorsPerTrack }
    public var byteCount: Int { sectorCount * sectorSize }
    public var megabytes: Double { Double(byteCount) / 1_048_576 }

    /// Drives of the period that ADFS formats with 32 sectors per track.
    /// The HD63463 addresses at most 1024 cylinders and 8 heads.
    public static let presets: [(name: String, geometry: HardDiscGeometry)] = [
        ("20 MB (Seagate ST225: 615 cylinders, 4 heads)", .init(cylinders: 615, heads: 4)),
        ("40 MB (Seagate ST251: 820 cylinders, 6 heads)", .init(cylinders: 820, heads: 6)),
        ("64 MB (1024 cylinders, 8 heads: the controller's limit)", .init(cylinders: 1024, heads: 8)),
    ]

    /// Geometry for an existing raw image: from the ADFS disc record in its
    /// boot block when the disc is formatted, else a preset of that size,
    /// else 8 heads and as many cylinders as fit.
    public static func infer(fileSize: Int, bootBlock: [UInt8]?, sectorSize: Int = 256) -> HardDiscGeometry? {
        if let b = bootBlock, b.count >= 0x200 {
            // Disc record at boot block +&1C0: log2 sector size, sectors
            // per track, heads, density, ... disc size (bytes) at +16.
            let r = 0x1C0
            let log2 = Int(b[r]), spt = Int(b[r + 1]), heads = Int(b[r + 2])
            if 1 << log2 == sectorSize, (1...255).contains(spt), (1...16).contains(heads) {
                let cylinders = fileSize / (spt * heads * sectorSize)
                if cylinders > 0 && cylinders <= 65535 {
                    return .init(cylinders: cylinders, heads: heads, sectorsPerTrack: spt, sectorSize: sectorSize)
                }
            }
        }
        let table = sectorSize == 256 ? presets : idePresets
        if let p = table.first(where: { $0.geometry.byteCount == fileSize }) { return p.geometry }
        let (heads, spt) = sectorSize == 256 ? (8, 32) : (16, 63)
        let track = heads * spt * sectorSize
        guard fileSize % track == 0, fileSize / track > 0 else { return nil }
        return .init(cylinders: fileSize / track, heads: heads, sectorsPerTrack: spt, sectorSize: sectorSize)
    }

    /// IDE drives (512-byte sectors); RISC OS 3.1's ADFS addresses up to 512 MB.
    public static let idePresets: [(name: String, geometry: HardDiscGeometry)] = [
        ("40 MB (Conner CP3044: 977 cylinders, 5 heads, 17 sectors)", .init(cylinders: 977, heads: 5, sectorsPerTrack: 17, sectorSize: 512)),
        ("120 MB (1024 cylinders, 8 heads, 30 sectors)", .init(cylinders: 1024, heads: 8, sectorsPerTrack: 30, sectorSize: 512)),
        ("250 MB (1010 cylinders, 16 heads, 32 sectors)", .init(cylinders: 1010, heads: 16, sectorsPerTrack: 32, sectorSize: 512)),
        ("500 MB (1015 cylinders, 16 heads, 63 sectors)", .init(cylinders: 1015, heads: 16, sectorsPerTrack: 63, sectorSize: 512)),
    ]
}

public enum HardDiscError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case unknownGeometry(String, Int)
    case create(String)
    public var description: String {
        switch self {
        case .cannotOpen(let p): return "Cannot open the hard disc image \(p) for reading and writing."
        case .unknownGeometry(let p, let n): return "\(p) (\(n) bytes) is not a recognisable hard disc image: the size should be a whole number of cylinders (heads x sectors x sector size)."
        case .create(let s): return "Cannot create the hard disc image: \(s)"
        }
    }
}

/// A raw hard disc image (sectors in cylinder, head, sector order), written
/// straight through to its file as a real drive would keep its data.
/// Save states and rewind record the image's path and `writeCount`, not its
/// contents.
public final class HardDiscImage {
    public let path: String
    public let geometry: HardDiscGeometry
    /// Sector writes since the image was opened.
    public private(set) var writeCount: UInt64 = 0
    private let fd: Int32

    private init(path: String, geometry: HardDiscGeometry, fd: Int32) {
        self.path = path; self.geometry = geometry; self.fd = fd
    }

    deinit { close(fd) }

    public static func open(path: String, sectorSize: Int = 256) throws -> HardDiscImage {
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0 else { throw HardDiscError.cannotOpen(path) }
        var st = stat()
        fstat(fd, &st)
        let size = Int(st.st_size)
        var boot = [UInt8](repeating: 0, count: 0x200)
        let got = pread(fd, &boot, 0x200, 0xC00)
        guard let g = HardDiscGeometry.infer(fileSize: size, bootBlock: got == 0x200 ? boot : nil, sectorSize: sectorSize) else {
            close(fd)
            throw HardDiscError.unknownGeometry(path, size)
        }
        return HardDiscImage(path: path, geometry: g, fd: fd)
    }

    /// A new, unformatted (zero-filled) image.
    @discardableResult
    public static func create(path: String, geometry: HardDiscGeometry) throws -> HardDiscImage {
        guard FileManager.default.createFile(atPath: path, contents: nil) else { throw HardDiscError.create(path) }
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0, ftruncate(fd, off_t(geometry.byteCount)) == 0 else {
            if fd >= 0 { close(fd) }
            throw HardDiscError.create(path)
        }
        return HardDiscImage(path: path, geometry: geometry, fd: fd)
    }

    func offset(cylinder: Int, head: Int, sector: Int) -> Int? {
        let g = geometry
        guard (0..<g.cylinders).contains(cylinder), (0..<g.heads).contains(head), (0..<g.sectorsPerTrack).contains(sector) else { return nil }
        return ((cylinder * g.heads + head) * g.sectorsPerTrack + sector) * g.sectorSize
    }

    /// One sector, or nil when (c, h, s) is not on the drive.
    public func read(cylinder: Int, head: Int, sector: Int) -> [UInt8]? {
        guard let o = offset(cylinder: cylinder, head: head, sector: sector) else { return nil }
        var b = [UInt8](repeating: 0, count: geometry.sectorSize)
        _ = pread(fd, &b, b.count, off_t(o))
        return b
    }

    /// While the debugger searches the rewind history, replayed writes are
    /// dropped: the file already holds the latest data.
    public var suppressWrites = false

    @discardableResult
    public func write(cylinder: Int, head: Int, sector: Int, _ data: [UInt8]) -> Bool {
        guard let o = offset(cylinder: cylinder, head: head, sector: sector) else { return false }
        if suppressWrites { return true }
        writeCount &+= 1
        return pwrite(fd, data, min(data.count, geometry.sectorSize), off_t(o)) == geometry.sectorSize
    }

    /// Push written data to the disc (on eject and quit).
    public func synchronize() { fsync(fd) }
}
