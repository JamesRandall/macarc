import AppKit

/// macOS virtual key codes (ANSI/ISO keyboards) to Archimedes key matrix codes.
enum KeyMap {
    static let table: [UInt16: UInt8] = [
        53: 0x00, // Escape
        122: 0x01, 120: 0x02, 99: 0x03, 118: 0x04, 96: 0x05, 97: 0x06, 98: 0x07, 100: 0x08,
        101: 0x09, 109: 0x0A, 103: 0x0B, 111: 0x0C, // F1-F12
        105: 0x0D, 107: 0x0E, 113: 0x0F, // F13 Print, F14 Scroll Lock, F15 Break
        50: 0x10, // ` (ISO: §)
        18: 0x11, 19: 0x12, 20: 0x13, 21: 0x14, 23: 0x15, 22: 0x16, 26: 0x17, 28: 0x18, 25: 0x19, 29: 0x1A,
        27: 0x1B, 24: 0x1C, // - =
        51: 0x1E, // Backspace
        114: 0x1F, // Help/Insert
        115: 0x20, 116: 0x21, // Home, PageUp
        71: 0x22, // Clear -> Num Lock
        75: 0x23, 67: 0x24, // keypad / *
        48: 0x26, // Tab
        12: 0x27, 13: 0x28, 14: 0x29, 15: 0x2A, 17: 0x2B, 16: 0x2C, 32: 0x2D, 34: 0x2E, 31: 0x2F, 35: 0x30,
        33: 0x31, 30: 0x32, 42: 0x33, // [ ] \
        117: 0x34, // Forward delete -> Delete
        119: 0x35, // End -> Copy
        121: 0x36, // PageDown
        89: 0x37, 91: 0x38, 92: 0x39, 78: 0x3A, // keypad 7 8 9 -
        59: 0x3B, // Left Control
        0: 0x3C, 1: 0x3D, 2: 0x3E, 3: 0x3F, 5: 0x40, 4: 0x41, 38: 0x42, 40: 0x43, 37: 0x44,
        41: 0x45, 39: 0x46, // ; '
        36: 0x47, // Return
        86: 0x48, 87: 0x49, 88: 0x4A, 69: 0x4B, // keypad 4 5 6 +
        56: 0x4C, // Left Shift
        6: 0x4E, 7: 0x4F, 8: 0x50, 9: 0x51, 11: 0x52, 45: 0x53, 46: 0x54, 43: 0x55, 47: 0x56, 44: 0x57,
        60: 0x58, // Right Shift
        126: 0x59, // Up
        83: 0x5A, 84: 0x5B, 85: 0x5C, // keypad 1 2 3
        57: 0x5D, // Caps Lock
        58: 0x5E, // Left Option -> Alt
        49: 0x5F, // Space
        61: 0x60, // Right Option -> Alt
        62: 0x61, // Right Control
        123: 0x62, 125: 0x63, 124: 0x64, // Left Down Right
        82: 0x65, 65: 0x66, 76: 0x67, // keypad 0 . Enter
        10: 0x1D, // ISO key left of Z / §: use for £
    ]

    /// Modifier keys arrive as flagsChanged: map keyCode -> (Arc code, flag).
    static let modifiers: [UInt16: (UInt8, NSEvent.ModifierFlags)] = [
        56: (0x4C, .shift), 60: (0x58, .shift), 59: (0x3B, .control), 62: (0x61, .control),
        58: (0x5E, .option), 61: (0x60, .option), 57: (0x5D, .capsLock),
    ]
}
