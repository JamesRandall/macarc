import Foundation

/// Setting up Acorn's Level 4 File Server on a machine, from the Level 4
/// floppy (Release 3 or Issue 2): a hard disc with the server's
/// applications and a boot file that starts it, and the configuration it
/// needs. MacArch includes none of Acorn's software; it copies it from the
/// disc the user has.
///
/// From the release note and the disc's own files: !Server needs !System
/// (with ABCLib and WimpMan) seen first, RMASize configured to 1024K, and
/// exports what its `Exports` file lists (as supplied, ADFS drive 4's root).
/// Release 3 needs RISC OS 3.10 or later.
public enum Level4 {
    public enum SetupError: Error, CustomStringConvertible {
        case notLevel4

        public var description: String {
            "That disc doesn't have Acorn's Level 4 File Server on it (no !Server and !System). It's the \"Level 4\" disc of Release 3, or the \"FileServer\" disc of Issue 2."
        }
    }

    /// The applications copied to the server's disc.
    static let applications: Set<String> = ["!SERVER", "!SYSTEM", "!MANAGER", "!NETUTILS", "!SPOOLER", "!MERGE"]

    /// Whether a floppy image holds Level 4.
    public static func isLevel4Disc(_ bytes: [UInt8]) -> Bool {
        guard let disc = try? ADFSDiscReader.read(bytes: bytes) else { return false }
        return isLevel4(disc.items)
    }

    static func isLevel4(_ items: [ADFSHardDiscBuilder.Item]) -> Bool {
        let paths = Set(items.map { $0.path.joined(separator: ".").uppercased() })
        return paths.contains("!SERVER.!RUNIMAGE") && paths.contains("!SYSTEM.!RUN")
    }

    /// Whether the disc's server needs RISC OS 3 (Release 3's !Run says
    /// so; Issue 2's loads its own Econet and NetFS modules instead).
    public static func requiresRISCOS3(_ bytes: [UInt8]) -> Bool {
        guard let disc = try? ADFSDiscReader.read(bytes: bytes),
              let run = disc.items.first(where: { $0.path.map { $0.uppercased() } == ["!SERVER", "!RUN"] }) else { return false }
        return String(decoding: run.data, as: UTF8.self).contains("RISC OS 3.10")
    }

    /// The boot file: !System seen, then the server started in the desktop.
    static let bootFile = """
        | MacArch: starts Acorn's Level 4 File Server
        /ADFS::4.$.!System
        Run ADFS::4.$.!Server.!Boot
        Desktop /ADFS::4.$.!Server

        """

    /// The files for the server's hard disc.
    public static func serverItems(fromDisc bytes: [UInt8]) throws -> [ADFSHardDiscBuilder.Item] {
        guard let disc = try? ADFSDiscReader.read(bytes: bytes), isLevel4(disc.items) else { throw SetupError.notLevel4 }
        var items = disc.items.filter { applications.contains($0.path[0].uppercased()) }
        let boot = Array(bootFile.utf8)
        items.append(ADFSHardDiscBuilder.Item(path: ["!Boot"], data: boot, type: 0xFEB))
        return items
    }

    /// Makes a hard disc at `path` that boots into the file server.
    public static func createServerDisc(path: String, geometry: HardDiscGeometry, fromDisc bytes: [UInt8]) throws {
        try ADFSHardDiscBuilder.create(path: path, geometry: geometry, name: "FileServer", items: try serverItems(fromDisc: bytes),
                                       bootOption: 2)
    }

    /// The configuration the server needs: ADFS drive 4 at start-up, its
    /// boot file run, and 1024K of RMA. (MEMC's pages are 8K per megabyte
    /// of memory, up to 32K.)
    public static func cmosSettings(ramKB: Int) -> [CMOSSetting] {
        let pageKB = min(32, max(8, ramKB / 128))
        return [.fileSystem(8), .drive(4), .boot, .rmaSize(pages: UInt8(1024 / pageKB))]
    }
}
