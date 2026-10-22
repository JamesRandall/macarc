import Foundation

/// A loaded operating system ROM image (contiguous, little-endian words).
public struct ROMImage: Sendable {
    public var data: [UInt8]
    public var sha256: String
    public var versionString: String
    public var sources: [String]
    public var layoutNote: String

    public enum ROMError: Error, CustomStringConvertible {
        case notFound(String)
        case empty
        case invalid(String)
        public var description: String {
            switch self {
            case .notFound(let p): return "ROM not found: \(p)"
            case .empty: return "No ROM files supplied"
            case .invalid(let s): return "ROM image invalid: \(s)"
            }
        }
    }

    /// Load from one file, several files, or a directory of files. Multiple
    /// files are combined in alphabetical order; if the result does not start
    /// with an ARM branch instruction, byte-interleaved chip sets (4 x 8-bit
    /// or 2 x 16-bit) are tried as well.
    public static func load(paths: [String]) throws -> ROMImage {
        var files: [String] = []
        let fm = FileManager.default
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { throw ROMError.notFound(p) }
            if isDir.boolValue {
                let names = try fm.contentsOfDirectory(atPath: p)
                    .filter { !$0.hasPrefix(".") && !$0.lowercased().hasSuffix(".txt") && !$0.lowercased().hasSuffix(".md") }
                    .sorted()
                files += names.map { (p as NSString).appendingPathComponent($0) }
            } else {
                files.append(p)
            }
        }
        guard !files.isEmpty else { throw ROMError.empty }
        let parts = try files.map { f -> [UInt8] in
            guard let d = fm.contents(atPath: f) else { throw ROMError.notFound(f) }
            return [UInt8](d)
        }
        return try build(parts: parts, sources: files)
    }

    public static func build(parts: [[UInt8]], sources: [String]) throws -> ROMImage {
        let concatenated = parts.flatMap { $0 }
        guard concatenated.count >= 1024 else { throw ROMError.invalid("only \(concatenated.count) bytes") }
        var candidates: [([UInt8], String)] = [(concatenated, parts.count == 1 ? "single image" : "\(parts.count) files concatenated in name order")]
        if parts.count == 4, Set(parts.map { $0.count }).count == 1 {
            let n = parts[0].count
            var out = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n { for c in 0..<4 { out[i * 4 + c] = parts[c][i] } }
            candidates.append((out, "4 x 8-bit chips byte-interleaved"))
        }
        if parts.count == 2, parts[0].count == parts[1].count {
            let n = parts[0].count / 2
            var out = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n {
                out[i * 4] = parts[0][i * 2]; out[i * 4 + 1] = parts[0][i * 2 + 1]
                out[i * 4 + 2] = parts[1][i * 2]; out[i * 4 + 3] = parts[1][i * 2 + 1]
            }
            candidates.append((out, "2 x 16-bit chips interleaved"))
        }
        for (d, note) in candidates where looksLikeRISCOS(d) {
            return ROMImage(data: d, sha256: SHA256.hex(d), versionString: findVersion(d), sources: sources, layoutNote: note)
        }
        throw ROMError.invalid("first word is not an ARM branch in any recognised chip layout (size \(concatenated.count) bytes)")
    }

    /// The reset vector of an Arthur/RISC OS ROM is a branch (cond AL).
    static func looksLikeRISCOS(_ d: [UInt8]) -> Bool {
        guard d.count >= 4 else { return false }
        let w = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
        return (w & 0xFF00_0000) == 0xEA00_0000 || (w & 0xFFFF_F000) == 0xE59F_F000
    }

    static func findVersion(_ d: [UInt8]) -> String {
        let needles = ["RISC OS", "Arthur"]
        for needle in needles {
            let n = Array(needle.utf8)
            var i = 0
            let limit = min(d.count - 40, 0x80000)
            while i < limit {
                if d[i] == n[0] && Array(d[i..<(i + n.count)]) == n {
                    var j = i
                    var s = ""
                    while j < d.count && j < i + 48 && d[j] >= 0x20 && d[j] < 0x7F { s.append(Character(UnicodeScalar(d[j]))); j += 1 }
                    if s.count > n.count + 2 && s.contains(where: { $0.isNumber }) { return s.trimmingCharacters(in: .whitespaces) }
                }
                i += 1
            }
        }
        return "unknown (\(d.count / 1024) KB)"
    }
}
