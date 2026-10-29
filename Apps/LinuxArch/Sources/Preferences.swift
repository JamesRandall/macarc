import Foundation

/// The app's settings, as MacArch keeps in UserDefaults: saved as JSON in
/// `$XDG_CONFIG_HOME/linuxarch/settings.json` (~/.config, or the app's own
/// in a Flatpak).
@MainActor
final class Preferences {
    static let standard = Preferences()

    private var values: [String: Any]
    private let url: URL
    private var saveScheduled = false

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        // Self-tests start from nothing, apart from the user's: their own
        // settings, ROMs and profiles (AppSettings.supportDirectory), as the
        // Mac app's self-tests have their own defaults. LINUXARCH_SETTINGS
        // gives another file.
        if AppSettings.isSelfTest {
            try? FileManager.default.removeItem(atPath: AppSettings.supportDirectory)
        }
        url = environment["LINUXARCH_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? (AppSettings.isSelfTest ? URL(fileURLWithPath: AppSettings.supportDirectory).appendingPathComponent("settings.json")
                : config.appendingPathComponent("linuxarch/settings.json"))
        values = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Whether anything has ever been saved (so this isn't the first run).
    var isEmpty: Bool { values.isEmpty }

    func object(forKey key: String) -> Any? { values[key] }

    func string(forKey key: String) -> String? { values[key] as? String }

    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }

    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }

    /// A Codable value, stored as JSON within the file.
    func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let value = values[key], JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    func set(_ value: String?, forKey key: String) {
        if let value { store(value, key) } else { removeObject(forKey: key) }
    }
    func set(_ value: Bool, forKey key: String) { store(value, key) }
    func set(_ value: Int, forKey key: String) { store(value, key) }
    func set(_ value: [String], forKey key: String) { store(value, key) }

    func setValue<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        store(object, key)
    }

    func removeObject(forKey key: String) {
        values[key] = nil
        scheduleSave()
    }

    private func store(_ value: Any, _ key: String) {
        values[key] = value
        scheduleSave()
    }

    /// Changes come in bursts (a slider, say): write once they settle.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        after(0.25) { [weak self] in self?.save() }
    }

    /// Writes now (when the app quits).
    func save() {
        saveScheduled = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("LinuxArch: can't save settings to \(url.path): \(error)")
        }
    }
}
