import AppKit
import Observation

/// The networks opened most recently, newest first, for File > Open Recent
/// Network and the start page.
@MainActor @Observable
final class RecentNetworks {
    static let shared = RecentNetworks()
    static let limit = 10
    private static let defaultsKey = "MacArchRecentNetworks"

    private(set) var urls: [URL]

    private init() {
        urls = (AppSettings.store.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// The ones still there.
    var existing: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        let url = NetworkSession.key(url)
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == NetworkSession.key(url) }
        save()
    }

    private func save() {
        AppSettings.store.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    /// Where new networks go: ~/Documents/MacArch Networks.
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacArch Networks", isDirectory: true)
    }

    /// A new package's place, named after `name` and not taken.
    static func newURL(named name: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(clean).appendingPathExtension(NetworkPackage.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(clean) \(n)").appendingPathExtension(NetworkPackage.fileExtension)
            n += 1
        }
        return candidate
    }
}
