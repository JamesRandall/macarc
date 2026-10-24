import Foundation

/// The Distributed Mandelbrot demo's network (after MacBeeb's): Acorn's
/// Level 4 File Server with the demo's programs in `$.LIBRARY`, workers
/// that boot from the network into `Worker`, and a coordinator that runs
/// `Mandel`. See Examples/distributed-mandelbrot/protocol.md.
public enum MandelbrotNetwork {
    /// The guest programs (Examples/distributed-mandelbrot), as the file
    /// server has them. The bytes are in MandelbrotGuestFiles.swift.
    public struct GuestFile: Sendable, Equatable {
        public var name: String
        /// The RISC OS filetype: Utility (&FFC) for Worker, which runs in
        /// the RMA; Absolute (&FF8) for Mandel, at &8000.
        public var type: UInt16
        public var contents: [UInt8]

        public init(name: String, type: UInt16, contents: [UInt8]) {
            self.name = name
            self.type = type
            self.contents = contents
        }

        init(name: String, type: UInt16, base64: String) {
            self.init(name: name, type: type, contents: [UInt8](Data(base64Encoded: base64) ?? Data()))
        }
    }

    /// The file server's station.
    public static let fileServer = 254

    /// The library the programs go in, where every logged-on station finds them.
    public static let library = "LIBRARY"

    /// NetFS's network boot logs on as BOOT (it's built in: `Logon Boot`)
    /// and runs `!ArmBoot` in its directory. (Not `!Boot`: a Level 4
    /// disc's `$.!Boot` is the server's own.) Level 4's supplied Users
    /// file has BOOT, with boot option 2 (*Run) and `BOOT` for its
    /// directory.
    public static let bootUser = "BOOT"
    public static let bootFile = """
        | Distributed Mandelbrot: a worker's network boot
        Run Net:$.LIBRARY.Worker

        """

    /// Read and write for the owner (SYST), read for everyone else: Level
    /// 4 refuses to open a file without it ("Insufficient access").
    static let publicRead: UInt8 = 0x13

    /// The server's files: Level 4's from the user's disc, the programs
    /// in `$.LIBRARY`, and the workers' boot file.
    public static func serverItems(fromLevel4Disc bytes: [UInt8]) throws -> [ADFSHardDiscBuilder.Item] {
        var items = try Level4.serverItems(fromDisc: bytes)
        func readable(_ path: [String], _ data: [UInt8], type: UInt16) -> ADFSHardDiscBuilder.Item {
            var item = ADFSHardDiscBuilder.Item(path: path, data: data, type: type)
            item.attributes = publicRead
            return item
        }
        for file in guestFiles {
            items.append(readable([library, file.name], file.contents, type: file.type))
        }
        items.append(readable([bootUser, "!ArmBoot"], Array(bootFile.utf8), type: 0xFEB))
        return items
    }

    /// The file server's hard disc, as an image.
    public static func fileServerDisc(fromLevel4Disc bytes: [UInt8], geometry: HardDiscGeometry) throws -> [UInt8] {
        try ADFSHardDiscBuilder.build(geometry: geometry, name: "FileServer", items: serverItems(fromLevel4Disc: bytes), bootOption: 2)
    }

    /// Makes the file server's hard disc at `path`.
    public static func createFileServerDisc(path: String, geometry: HardDiscGeometry, fromLevel4Disc bytes: [UInt8]) throws {
        try ADFSHardDiscBuilder.create(path: path, geometry: geometry, name: "FileServer", items: serverItems(fromLevel4Disc: bytes),
                                       bootOption: 2)
    }

    /// The Guide's hard disc: a boot file that selects the network, logs
    /// on as GUEST and leaves the teacher at a `*` prompt to type Mandel.
    /// (Nothing of Acorn's on it: only MacArch's boot file.)
    public static let guideBootFile = """
        | Distributed Mandelbrot: the Guide
        Net
        Logon GUEST
        Echo <22><12>
        Echo Welcome to the Distributed Mandelbrot!
        Echo
        Echo This machine is the Guide. The other Archimedes on the network are the
        Echo workers: they've started up from the file server, and they're waiting
        Echo for something to do.
        Echo
        Echo To have them draw the Mandelbrot set together, type   Mandel   and press
        Echo Return. The Guide hands out the picture a tile at a time; each worker
        Echo works out its tiles and sends them back over Econet.
        Echo
        Echo Watch the workers' screens too. Try switching one off part way through:
        Echo the others pick up its tiles. When the picture's done, press any key.
        Echo
        Echo To send the workers back to waiting, type   Mandel Stop
        Echo
        Gos

        """

    public static func guideItems() -> [ADFSHardDiscBuilder.Item] {
        [ADFSHardDiscBuilder.Item(path: ["!Boot"], data: Array(guideBootFile.utf8), type: 0xFEB)]
    }

    /// Makes the Guide's hard disc at `path`.
    public static func createGuideDisc(path: String, geometry: HardDiscGeometry) throws {
        try ADFSHardDiscBuilder.create(path: path, geometry: geometry, name: "Guide", items: guideItems(), bootOption: 2)
    }

    /// The Guide's configuration: boot from its hard disc (ADFS drive 4),
    /// with the file server's station for its log-on.
    public static func guideCMOSSettings(fileServer station: Int = fileServer) -> [CMOSSetting] {
        [.fileSystem(8), .drive(4), .boot, CMOSSetting(byte: 1, value: UInt8(clamping: station)), CMOSSetting(byte: 2, value: 0)]
    }

    /// A worker's configuration: NetFS at start-up (FileSystem 5), the
    /// file server's station (bytes 1-2), and boot (byte 16 bit 4), so it
    /// logs on and runs its boot file at power-on.
    public static func workerCMOSSettings(fileServer station: Int = fileServer) -> [CMOSSetting] {
        netFS(station) + [.boot]
    }

    /// The coordinator's: NetFS and the file server, but no boot (the
    /// network boot's for workers: it would log on as BOOT, and work).
    public static func coordinatorCMOSSettings(fileServer station: Int = fileServer) -> [CMOSSetting] {
        netFS(station) + [CMOSSetting(byte: CMOSSetting.boot.byte, mask: CMOSSetting.boot.mask, value: 0)]
    }

    static func netFS(_ station: Int) -> [CMOSSetting] {
        [.fileSystem(5), CMOSSetting(byte: 1, value: UInt8(clamping: station)), CMOSSetting(byte: 2, value: 0)]
    }
}
