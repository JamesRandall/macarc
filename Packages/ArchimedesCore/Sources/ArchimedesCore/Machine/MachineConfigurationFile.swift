import Foundation

/// The same JSON object as MachineConfiguration, with paths relative to its file.
/// CMOS travels in a neighbouring file; ROMs and discs remain external references.
public enum MachineConfigurationFile {
    public static func load(from url: URL) throws -> MachineConfiguration {
        var c = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: url))
        try validate(c)
        let directory = url.deletingLastPathComponent()
        func resolve(_ path: String) throws -> String {
            guard !path.isEmpty else { throw MachineError.badConfiguration("An image path is empty") }
            let expanded = (path as NSString).expandingTildeInPath
            let p = (expanded as NSString).isAbsolutePath ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            guard FileManager.default.fileExists(atPath: p.path) else {
                throw MachineError.badConfiguration("File not found: \(p.path)")
            }
            return p.standardizedFileURL.path
        }
        c.romPaths = try c.romPaths.map(resolve)
        c.hardDiscs = try c.hardDiscs.map { try $0.map(resolve) }
        c.cmosPath = try c.cmosPath.map(resolve)
        if let path = c.cmosPath, try Data(contentsOf: URL(fileURLWithPath: path)).count != 256 {
            throw MachineError.badConfiguration("CMOS must contain exactly 256 bytes")
        }
        return c
    }

    public static func validate(_ c: MachineConfiguration) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw MachineError.badConfiguration(message) }
        }
        try require((1...MachineConfiguration.currentVersion).contains(c.version), "Unsupported machine configuration version \(c.version)")
        try require(!c.romPaths.isEmpty, "No ROM images configured")
        try require(c.model.ramChoices.contains(c.ramKB), "Unsupported memory size for \(c.model.rawValue)")
        try require(c.model.cpuChoices.contains(c.cpu), "Unsupported processor for \(c.model.rawValue)")
        try require(MonitorType(rawValue: c.monitor).map { c.model.monitorChoices.contains($0) } ?? false, "Unsupported monitor for \(c.model.rawValue)")
        try require(c.hardDiscs.count <= c.model.hardDiscSlots, "Too many hard discs for \(c.model.rawValue)")
        try require(c.floppyController == "WD1772", "Unsupported floppyController value; the fitted controller is selected by the machine model")
        try require((0...60_000).contains(c.powerOnKeysMs), "Power-on key duration must be between 0 and 60000 ms")
        try require(c.cmosSettings.allSatisfy { (0...239).contains($0.byte) && $0.value & ~$0.mask == 0 }, "Invalid CMOS byte or mask")
        if let station = c.econetStation {
            try require(c.model.takesEconet && (1...254).contains(station), "Invalid Econet station for this model")
        }
    }

    /// Save the current CMOS, not an old boot-time file. A unique sidecar avoids
    /// overwriting a file referenced by another configuration. JSON is replaced last.
    public static func save(_ configuration: MachineConfiguration, cmos: [UInt8], to url: URL) throws {
        var c = configuration
        c.version = MachineConfiguration.currentVersion
        try validate(c)
        guard cmos.count == 256 else { throw MachineError.badConfiguration("CMOS must contain exactly 256 bytes") }
        let directory = url.deletingLastPathComponent().standardizedFileURL
        func portable(_ path: String) -> String {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            return file.deletingLastPathComponent() == directory ? file.lastPathComponent : file.path
        }
        c.romPaths = c.romPaths.map(portable)
        c.hardDiscs = c.hardDiscs.map { $0.map(portable) }
        let sidecar = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + ".cmos")
        c.cmosPath = sidecar.lastPathComponent
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(c)
        try Data(cmos).write(to: sidecar, options: .atomic)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: sidecar); throw error }
    }
}
