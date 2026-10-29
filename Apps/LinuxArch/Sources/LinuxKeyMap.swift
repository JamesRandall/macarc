/// Linux key codes (evdev's, as `linux/input-event-codes.h` numbers them) to
/// Archimedes key matrix codes, by position: each PC key is the Archimedes
/// key in the same place. (The Mac app's KeyMap, for PC keyboards.) GDK's
/// hardware keycodes are evdev's plus 8, on Wayland and X11 alike.
enum LinuxKeyMap {
    static func evdev(gdkKeycode: UInt32) -> UInt16? {
        gdkKeycode >= 8 ? UInt16(gdkKeycode - 8) : nil
    }

    static let table: [UInt16: UInt8] = [
        1: 0x00, // Escape
        59: 0x01, 60: 0x02, 61: 0x03, 62: 0x04, 63: 0x05, 64: 0x06, 65: 0x07, 66: 0x08,
        67: 0x09, 68: 0x0A, 87: 0x0B, 88: 0x0C, // F1-F12
        99: 0x0D, 70: 0x0E, 119: 0x0F, // Print, Scroll Lock, Pause -> Break
        41: 0x10, // ` (UK: ¬)
        2: 0x11, 3: 0x12, 4: 0x13, 5: 0x14, 6: 0x15, 7: 0x16, 8: 0x17, 9: 0x18, 10: 0x19, 11: 0x1A,
        12: 0x1B, 13: 0x1C, // - =
        14: 0x1E, // Backspace
        110: 0x1F, 102: 0x20, 104: 0x21, // Insert, Home, Page Up
        69: 0x22, // Num Lock
        98: 0x23, 55: 0x24, // keypad / *
        15: 0x26, // Tab
        16: 0x27, 17: 0x28, 18: 0x29, 19: 0x2A, 20: 0x2B, 21: 0x2C, 22: 0x2D, 23: 0x2E, 24: 0x2F, 25: 0x30,
        26: 0x31, 27: 0x32, 43: 0x33, // [ ] \ (UK: #)
        111: 0x34, // Delete
        107: 0x35, // End -> Copy
        109: 0x36, // Page Down
        71: 0x37, 72: 0x38, 73: 0x39, 74: 0x3A, // keypad 7 8 9 -
        29: 0x3B, // Left Control
        30: 0x3C, 31: 0x3D, 32: 0x3E, 33: 0x3F, 34: 0x40, 35: 0x41, 36: 0x42, 37: 0x43, 38: 0x44,
        39: 0x45, 40: 0x46, // ; '
        28: 0x47, // Return
        75: 0x48, 76: 0x49, 77: 0x4A, 78: 0x4B, // keypad 4 5 6 +
        42: 0x4C, // Left Shift
        44: 0x4E, 45: 0x4F, 46: 0x50, 47: 0x51, 48: 0x52, 49: 0x53, 50: 0x54, 51: 0x55, 52: 0x56, 53: 0x57,
        54: 0x58, // Right Shift
        103: 0x59, // Up
        79: 0x5A, 80: 0x5B, 81: 0x5C, // keypad 1 2 3
        58: 0x5D, // Caps Lock
        56: 0x5E, // Left Alt
        57: 0x5F, // Space
        100: 0x60, // Right Alt (AltGr)
        97: 0x61, // Right Control
        105: 0x62, 108: 0x63, 106: 0x64, // Left Down Right
        82: 0x65, 83: 0x66, 96: 0x67, // keypad 0 . Enter
        86: 0x1D, // the ISO key left of Z (UK: \): £, which a PC hasn't
    ]

    /// The Super (Windows) keys, which belong to the desktop.
    static let superKeys: Set<UInt16> = [125, 126]

    /// Keys that stay positional in host-layout mode: arrows, function
    /// keys, editing keys, Return, Tab, Escape, Backspace, the modifiers and
    /// the keypad.
    static let positionalKeys: Set<UInt16> = [
        1, 14, 15, 28, 29, 42, 54, 56, 58, 97, 100, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88, 99, 70, 119,
        110, 102, 104, 111, 107, 109, 103, 105, 108, 106, 69, 98, 55, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 96,
    ]

    /// Names for keys whose label isn't a character, for the settings list.
    static let names: [UInt16: String] = [
        1: "Escape", 14: "Backspace", 15: "Tab", 28: "Return", 57: "Space", 111: "Delete", 110: "Insert",
        102: "Home", 107: "End", 104: "Page Up", 109: "Page Down",
        103: "Up", 108: "Down", 105: "Left", 106: "Right",
        42: "Left Shift", 54: "Right Shift", 29: "Left Ctrl", 97: "Right Ctrl", 56: "Left Alt", 100: "Right Alt (AltGr)",
        58: "Caps Lock", 69: "Num Lock", 70: "Scroll Lock", 99: "Print Screen", 119: "Pause",
        125: "Left Super", 126: "Right Super", 127: "Menu",
        59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6", 65: "F7", 66: "F8", 67: "F9", 68: "F10",
        87: "F11", 88: "F12", 183: "F13", 184: "F14", 185: "F15", 186: "F16",
        98: "Keypad /", 55: "Keypad *", 74: "Keypad -", 78: "Keypad +", 96: "Keypad Enter", 83: "Keypad .",
        82: "Keypad 0", 79: "Keypad 1", 80: "Keypad 2", 81: "Keypad 3", 75: "Keypad 4", 76: "Keypad 5",
        77: "Keypad 6", 71: "Keypad 7", 72: "Keypad 8", 73: "Keypad 9", 86: "ISO Key (left of Z)",
    ]
}
