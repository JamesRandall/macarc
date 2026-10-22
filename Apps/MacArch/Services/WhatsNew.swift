import Foundation

/// The release notes in WHATSNEW.md (copied into the app's Resources), and
/// whether to show them: once, on the first launch after an update.
enum WhatsNew {
    struct Release: Identifiable {
        var version: String
        var date: String?
        var intro: [String]
        var items: [String]
        var id: String { version }
    }

    /// Every release, newest first.
    static let releases: [Release] = {
        guard let text = source.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return [] }
        return parse(text)
    }()

    /// The bundled copy, or the repo's when run with `swift run`.
    private static var source: URL? {
        Bundle.main.url(forResource: "WhatsNew", withExtension: "md")
            ?? [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../WHATSNEW.md").standardized]
                .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        var inComment = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inComment { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("<!--") { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3).split(separator: "—", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                releases.append(Release(version: heading[0], date: heading.count > 1 ? heading[1] : nil, intro: [], items: []))
            } else if releases.isEmpty || line.isEmpty || line.hasPrefix("#") {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                releases[releases.count - 1].items.append(String(line.dropFirst(2)))
            } else if !releases[releases.count - 1].items.isEmpty {
                // A wrapped bullet.
                releases[releases.count - 1].items[releases[releases.count - 1].items.count - 1] += " " + line
            } else {
                releases[releases.count - 1].intro.append(line)
            }
        }
        return releases
    }

    /// "1.2" sorts as "1.2.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The version the user last ran, before this launch.
    private(set) static var previousVersion: String?
    private static var checked = false

    /// Called once per launch: records this version as seen, and says
    /// whether there are notes the user hasn't seen. A fresh install has
    /// the welcome screen instead.
    static func shouldShowOnLaunch() -> Bool {
        guard !checked else { return false }
        checked = true
        let d = AppSettings.store
        let env = ProcessInfo.processInfo.environment
        let last = env["MACARCH_SELFTEST_WHATSNEW"] ?? d.string(forKey: "whatsNewSeen")
        previousVersion = last
        d.set(currentVersion, forKey: "whatsNewSeen")
        guard let last else { return false }
        return releases.contains { isNew($0, since: last) }
    }

    /// Newer than `since` but not newer than this build.
    static func isNew(_ r: Release, since: String?) -> Bool {
        guard let since else { return false }
        return isNewer(r.version, than: since) && !isNewer(r.version, than: currentVersion)
    }
}
