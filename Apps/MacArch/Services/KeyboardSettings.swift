import AppKit
import ArchimedesCore
import Observation

/// Custom key assignments, shared by all windows and saved. They take
/// priority over the built-in positional map (`KeyMap`).
@MainActor
@Observable
final class KeyboardSettings {
    static let shared = KeyboardSettings()

    struct Mapping: Codable, Hashable, Identifiable {
        /// macOS virtual key code.
        var keyCode: UInt16
        /// The Mac key's name when it was recorded, e.g. "F13" or "§".
        var macKeyName: String
        /// Archimedes key matrix code.
        var arcKey: UInt8
        var id: UInt16 { keyCode }
    }

    /// How keys are translated. Saved; shared by all windows.
    enum Mode: String, CaseIterable, Identifiable {
        /// Each Mac key is the Archimedes key in the same place.
        case physical
        /// Keys type the character the Mac's layout gives.
        case macLayout
        var id: Self { self }
        var name: String { self == .physical ? "Archimedes layout (by key position)" : "Mac layout (by character typed)" }
    }

    var mode: Mode {
        didSet { AppSettings.store.set(mode.rawValue, forKey: Self.modeKey); modeValue = mode }
    }
    /// Read on every key event, off the observation machinery.
    @ObservationIgnored private(set) nonisolated(unsafe) var modeValue: Mode = .physical
    private static let modeKey = "MacArchKeyboardMode"

    /// Sorted by Mac key name.
    private(set) var mappings: [Mapping] {
        didSet {
            if let data = try? JSONEncoder().encode(mappings) { AppSettings.store.set(data, forKey: Self.mappingsKey) }
            rebuild()
        }
    }

    /// Lookup used on every key event.
    @ObservationIgnored private(set) nonisolated(unsafe) var customKeys: [UInt16: UInt8] = [:]

    private static let mappingsKey = "MacArchKeyMappings"

    private init() {
        mode = AppSettings.store.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .physical
        mappings = AppSettings.store.data(forKey: Self.mappingsKey)
            .flatMap { try? JSONDecoder().decode([Mapping].self, from: $0) } ?? []
        rebuild()
        modeValue = mode
    }

    private func rebuild() {
        customKeys = Dictionary(mappings.map { ($0.keyCode, $0.arcKey) }) { _, last in last }
    }

    func setMapping(keyCode: UInt16, macKeyName: String, to key: UInt8) {
        var m = mappings.filter { $0.keyCode != keyCode }
        m.append(Mapping(keyCode: keyCode, macKeyName: macKeyName, arcKey: key))
        m.sort { $0.macKeyName.localizedStandardCompare($1.macKeyName) == .orderedAscending }
        mappings = m
    }

    func removeMapping(keyCode: UInt16) { mappings.removeAll { $0.keyCode == keyCode } }
    func removeAllMappings() { mappings = [] }

    /// What a Mac key does now (custom, then positional), for new mappings.
    func currentKey(for keyCode: UInt16) -> UInt8 {
        customKeys[keyCode] ?? KeyMap.table[keyCode] ?? KeyMap.modifiers[keyCode]?.0 ?? 0x5F
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

    /// A name for a Mac key, for the settings list.
    static func name(of event: NSEvent) -> String {
        if let n = macKeyNames[event.keyCode] { return n }
        if let c = event.charactersIgnoringModifiers?.uppercased(), let s = c.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(s) { return c }
        return "Key \(event.keyCode)"
    }

    private static let macKeyNames: [UInt16: String] = [
        53: "Escape", 48: "Tab", 49: "Space", 36: "Return", 51: "Delete", 117: "Forward Delete",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        56: "Left Shift", 60: "Right Shift", 59: "Left Control", 62: "Right Control",
        58: "Left Option", 61: "Right Option", 55: "Left Command", 54: "Right Command", 57: "Caps Lock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 10: "§",
    ]
}

/// Captures the next key press (including modifier keys) in the app.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    init(onKey: @escaping (NSEvent) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged && !Self.isPress(event) { return nil }
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// For a flagsChanged event: is the modifier going down?
    nonisolated static func isPress(_ event: NSEvent) -> Bool {
        let flag: NSEvent.ModifierFlags = switch event.keyCode {
        case 56, 60: .shift
        case 59, 62: .control
        case 58, 61: .option
        case 55, 54: .command
        case 57: .capsLock
        default: .function
        }
        return event.modifierFlags.contains(flag)
    }
}
