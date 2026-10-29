import ArchimedesCore
import Foundation
import Observation

/// How keys are translated, and custom key assignments, shared by all
/// windows and saved. Assignments take priority over the built-in
/// positional map (`LinuxKeyMap`). (The Mac app's KeyboardSettings, with
/// Linux key codes for the Mac's.)
@MainActor
@Observable
final class KeyboardSettings {
    static let shared = KeyboardSettings()

    struct Mapping: Codable, Hashable, Identifiable {
        /// Linux (evdev) key code.
        var keyCode: UInt16
        /// The key's name when it was recorded, e.g. "F13" or "\".
        var keyName: String
        /// Archimedes key matrix code.
        var arcKey: UInt8
        var id: UInt16 { keyCode }
    }

    /// How keys are translated. Saved; shared by all windows.
    enum Mode: String, CaseIterable, Identifiable {
        /// Each PC key is the Archimedes key in the same place.
        case physical
        /// Keys type the character the desktop's layout gives.
        case hostLayout
        var id: Self { self }
        var name: String { self == .physical ? "Archimedes layout (by key position)" : "Your keyboard’s layout (by character typed)" }
        var shortName: String { self == .physical ? "By position" : "By character" }
    }

    var mode: Mode {
        didSet { Preferences.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    private static let modeKey = "keyboardMode"

    /// Sorted by key name.
    private(set) var mappings: [Mapping] {
        didSet {
            Preferences.standard.setValue(mappings, forKey: Self.mappingsKey)
            rebuild()
        }
    }

    /// Lookup used on every key event.
    @ObservationIgnored private(set) var customKeys: [UInt16: UInt8] = [:]

    private static let mappingsKey = "keyMappings"

    private init() {
        mode = Preferences.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .physical
        mappings = Preferences.standard.value([Mapping].self, forKey: Self.mappingsKey) ?? []
        rebuild()
    }

    private func rebuild() {
        customKeys = Dictionary(mappings.map { ($0.keyCode, $0.arcKey) }) { _, last in last }
    }

    func setMapping(keyCode: UInt16, keyName: String, to key: UInt8) {
        var m = mappings.filter { $0.keyCode != keyCode }
        m.append(Mapping(keyCode: keyCode, keyName: keyName, arcKey: key))
        m.sort { $0.keyName.localizedStandardCompare($1.keyName) == .orderedAscending }
        mappings = m
    }

    func removeMapping(keyCode: UInt16) { mappings.removeAll { $0.keyCode == keyCode } }
    func removeAllMappings() { mappings = [] }

    /// What a key does now (custom, then positional), for new mappings.
    func currentKey(for keyCode: UInt16) -> UInt8 {
        customKeys[keyCode] ?? LinuxKeyMap.table[keyCode] ?? 0x5F
    }

    /// The Archimedes keys, for pickers: (name, code), in keyboard order.
    static let catalogue: [(name: String, code: UInt8)] = {
        var byCode: [UInt8: String] = [:]
        for (name, code) in ArcKey.names where byCode[code] == nil || name.count > byCode[code]!.count {
            byCode[code] = name
        }
        return byCode.sorted { $0.key < $1.key }.map { (displayName($0.value), $0.key) }
    }()

    static func displayName(_ name: String) -> String {
        switch name {
        case "select", "menu", "adjust": return "Mouse " + name.capitalized
        case _ where name.hasPrefix("kp"): return "Keypad " + name.dropFirst(2)
        case _ where name.count == 1: return name.uppercased()
        case _ where name.first == "f" && Int(name.dropFirst()) != nil: return name.uppercased()
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// A name for a PC key, for the settings list: its label, or the
    /// character it types.
    static func name(keyCode: UInt16, character: String?) -> String {
        if let n = LinuxKeyMap.names[keyCode] { return n }
        if let c = character?.uppercased(), let s = c.unicodeScalars.first, !CharacterSet.controlCharacters.contains(s),
           !CharacterSet.whitespaces.contains(s) {
            return c
        }
        return "Key \(keyCode)"
    }
}
