/// The Archimedes keyboard (and attached mouse) as seen over the IOC KART
/// serial link. Implements the handshake protocol: HRST/RAK1/RAK2 reset,
/// two-byte key and mouse reports each acknowledged with BACK followed by a
/// scan-mode acknowledge (NACK/SACK/MACK/SMAK), and the request commands.
public final class Keyboard {
    // Host -> keyboard
    static let HRST: UInt8 = 0xFF, RAK1: UInt8 = 0xFE, RAK2: UInt8 = 0xFD
    static let BACK: UInt8 = 0x3F, SMAK: UInt8 = 0x33, MACK: UInt8 = 0x32, SACK: UInt8 = 0x31, NACK: UInt8 = 0x30
    static let RQMP: UInt8 = 0x22, PRST: UInt8 = 0x21, RQID: UInt8 = 0x20
    // Keyboard -> host
    static let KDDA: UInt8 = 0xC0, KUDA: UInt8 = 0xD0, PDAT: UInt8 = 0xE0
    static let keyboardID: UInt8 = 0x81 // UK keyboard

    enum State: UInt8, Equatable { case awaitingReset, awaitingRAK1, awaitingRAK2, awaitingByteAck, awaitingAck, idle }

    struct Pending { var byte: UInt8; var next: State; var kind: Kind }
    enum Kind: UInt8 { case protocolByte, key, mouse }

    var state: State = .awaitingReset
    var keyScan = false
    var mouseScan = false
    var queue: [Pending] = []
    /// Keys currently held (by code), including mouse buttons 0x70-0x72.
    public private(set) var held = Set<UInt8>()
    var mouseDX = 0
    var mouseDY = 0
    public private(set) var leds: UInt8 = 0
    public var log: ((String) -> Void)?

    public init() {}

    /// Byte available for transmission to IOC, if the protocol allows one now.
    func nextByteToSend() -> UInt8? {
        guard state == .idle else { return nil }
        if queue.isEmpty, mouseScan, mouseDX != 0 || mouseDY != 0 { queueMouseReport() }
        return queue.first?.byte
    }

    /// Commit the byte returned by `nextByteToSend` as transmitted.
    func byteSent() {
        guard !queue.isEmpty else { return }
        let p = queue.removeFirst()
        state = p.next
    }

    func receive(_ b: UInt8) {
        switch b {
        case Self.HRST:
            // A hard reset request always restarts the protocol.
            queue.removeAll()
            keyScan = false; mouseScan = false
            state = .idle
            queue.append(Pending(byte: Self.HRST, next: .awaitingRAK1, kind: .protocolByte))
        case Self.RAK1:
            if state == .awaitingRAK1 {
                state = .idle
                queue.append(Pending(byte: Self.RAK1, next: .awaitingRAK2, kind: .protocolByte))
            } else { protocolError() }
        case Self.RAK2:
            if state == .awaitingRAK2 {
                state = .idle
                queue.append(Pending(byte: Self.RAK2, next: .awaitingAck, kind: .protocolByte))
            } else { protocolError() }
        case Self.BACK:
            if state == .awaitingByteAck { state = .idle } else { protocolError() }
        case Self.NACK, Self.SACK, Self.MACK, Self.SMAK:
            if state == .awaitingAck || state == .idle {
                let wasKeyScan = keyScan
                keyScan = b & 1 != 0
                mouseScan = b & 2 != 0
                state = .idle
                if !keyScan { queue.removeAll { $0.kind == .key } } else if !wasKeyScan { reportHeldKeys() }
                if !mouseScan { queue.removeAll { $0.kind == .mouse } }
            } else { protocolError() }
        case Self.RQMP:
            if state == .awaitingAck { state = .idle }
            queueMouseReport(force: true)
        case Self.PRST:
            break
        case Self.RQID:
            if state == .awaitingAck { state = .idle }
            queue.append(Pending(byte: Self.keyboardID, next: .awaitingAck, kind: .protocolByte))
        case 0x40...0x4F:
            if state == .awaitingAck { state = .idle }
            queue.append(Pending(byte: Self.PDAT | (b & 0xF), next: .awaitingAck, kind: .protocolByte))
        case 0x00...0x07:
            leds = b
        default:
            protocolError()
        }
    }

    func protocolError() {
        log?("keyboard protocol error in state \(state)")
        queue.removeAll()
        keyScan = false; mouseScan = false
        state = .idle
        queue.append(Pending(byte: Self.HRST, next: .awaitingReset, kind: .protocolByte))
    }

    func reportHeldKeys() {
        for k in held.sorted() { queueKey(k, down: true) }
    }

    func queueKey(_ code: UInt8, down: Bool) {
        let base = down ? Self.KDDA : Self.KUDA
        queue.append(Pending(byte: base | (code >> 4), next: .awaitingByteAck, kind: .key))
        queue.append(Pending(byte: base | (code & 0xF), next: .awaitingAck, kind: .key))
    }

    func queueMouseReport(force: Bool = false) {
        let dx = max(-64, min(63, mouseDX))
        let dy = max(-64, min(63, mouseDY))
        if !force && dx == 0 && dy == 0 { return }
        mouseDX -= dx; mouseDY -= dy
        queue.append(Pending(byte: UInt8(truncatingIfNeeded: dx) & 0x7F, next: .awaitingByteAck, kind: .mouse))
        queue.append(Pending(byte: UInt8(truncatingIfNeeded: dy) & 0x7F, next: .awaitingAck, kind: .mouse))
    }

    // MARK: Host input

    public func keyDown(_ code: UInt8) {
        guard !held.contains(code) else { return }
        held.insert(code)
        if keyScan { queueKey(code, down: true) }
    }

    public func keyUp(_ code: UInt8) {
        guard held.contains(code) else { return }
        held.remove(code)
        if keyScan { queueKey(code, down: false) }
    }

    /// Relative mouse movement in guest units; +y is up.
    public func mouseMove(dx: Int, dy: Int) {
        mouseDX += dx
        mouseDY += dy
        // Avoid unbounded accumulation if the guest is not scanning.
        mouseDX = max(-4096, min(4096, mouseDX))
        mouseDY = max(-4096, min(4096, mouseDY))
    }

    public func releaseAll() {
        for k in held.sorted() { keyUp(k) }
    }
}

/// Archimedes key matrix codes.
public enum ArcKey {
    public static let names: [String: UInt8] = [
        "escape": 0x00, "f1": 0x01, "f2": 0x02, "f3": 0x03, "f4": 0x04, "f5": 0x05, "f6": 0x06,
        "f7": 0x07, "f8": 0x08, "f9": 0x09, "f10": 0x0A, "f11": 0x0B, "f12": 0x0C,
        "print": 0x0D, "scrolllock": 0x0E, "break": 0x0F,
        "`": 0x10, "1": 0x11, "2": 0x12, "3": 0x13, "4": 0x14, "5": 0x15, "6": 0x16, "7": 0x17,
        "8": 0x18, "9": 0x19, "0": 0x1A, "-": 0x1B, "=": 0x1C, "pound": 0x1D, "backspace": 0x1E,
        "insert": 0x1F, "home": 0x20, "pageup": 0x21, "numlock": 0x22, "kp/": 0x23, "kp*": 0x24, "kp#": 0x25,
        "tab": 0x26, "q": 0x27, "w": 0x28, "e": 0x29, "r": 0x2A, "t": 0x2B, "y": 0x2C, "u": 0x2D,
        "i": 0x2E, "o": 0x2F, "p": 0x30, "[": 0x31, "]": 0x32, "\\": 0x33, "delete": 0x34, "copy": 0x35,
        "pagedown": 0x36, "kp7": 0x37, "kp8": 0x38, "kp9": 0x39, "kp-": 0x3A, "ctrl": 0x3B,
        "a": 0x3C, "s": 0x3D, "d": 0x3E, "f": 0x3F, "g": 0x40, "h": 0x41, "j": 0x42, "k": 0x43,
        "l": 0x44, ";": 0x45, "'": 0x46, "return": 0x47, "kp4": 0x48, "kp5": 0x49, "kp6": 0x4A,
        "kp+": 0x4B, "shift": 0x4C, "z": 0x4E, "x": 0x4F, "c": 0x50, "v": 0x51, "b": 0x52,
        "n": 0x53, "m": 0x54, ",": 0x55, ".": 0x56, "/": 0x57, "rshift": 0x58, "up": 0x59,
        "kp1": 0x5A, "kp2": 0x5B, "kp3": 0x5C, "capslock": 0x5D, "alt": 0x5E, "space": 0x5F,
        "ralt": 0x60, "rctrl": 0x61, "left": 0x62, "down": 0x63, "right": 0x64, "kp0": 0x65,
        "kp.": 0x66, "enter": 0x67,
        "select": 0x70, "menu": 0x71, "adjust": 0x72,
    ]

    /// Map a printable character to (key code, needs shift) on a UK layout.
    /// Key and Shift state that type `c` under RISC OS 3.11's UK keyboard
    /// handler (measured by typing every key with and without Shift at the
    /// command line). Used for scripted typing and the app's Mac-layout mode.
    public static func forCharacter(_ c: Character) -> (UInt8, Bool)? {
        if c == " " { return (0x5F, false) }
        if c == "\n" || c == "\r" { return (0x47, false) }
        if c == "\t" { return (0x26, false) }
        if c.isLetter, c.isASCII { return (names[String(c).lowercased()]!, c.isUppercase) }
        if c == "£" { return (0x1D, false) }
        let plain = "`1234567890-=[]\\;',./"
        let shifted = "~!@#$%^&*()_+{}|:\"<>?"
        if plain.contains(c) { return (names[String(c)]!, false) }
        if let i = shifted.firstIndex(of: c) {
            let base = plain[plain.index(plain.startIndex, offsetBy: shifted.distance(from: shifted.startIndex, to: i))]
            return (names[String(base)]!, true)
        }
        return nil
    }
}

// MARK: - Snapshot state

extension Keyboard {
    func saveState(_ w: inout StateWriter) {
        w.u8(state.rawValue); w.bool(keyScan); w.bool(mouseScan)
        w.u32(UInt32(queue.count))
        for p in queue { w.u8(p.byte); w.u8(p.next.rawValue); w.u8(p.kind.rawValue) }
        w.data(held.sorted()); w.i64(mouseDX); w.i64(mouseDY); w.u8(leds)
    }

    func loadState(_ r: inout StateReader) throws {
        func state(_ v: UInt8) throws -> State {
            guard let s = State(rawValue: v) else { throw SnapshotError.corrupt("keyboard state \(v)") }
            return s
        }
        self.state = try state(try r.u8()); keyScan = try r.bool(); mouseScan = try r.bool()
        let n = Int(try r.u32())
        guard n < 1 << 16 else { throw SnapshotError.corrupt("keyboard queue length \(n)") }
        queue = try (0..<n).map { _ in
            let b = try r.u8(), next = try state(try r.u8())
            guard let k = Kind(rawValue: try r.u8()) else { throw SnapshotError.corrupt("keyboard byte kind") }
            return Pending(byte: b, next: next, kind: k)
        }
        held = Set(try r.data(max: 256)); mouseDX = try r.i64(); mouseDY = try r.i64(); leds = try r.u8()
    }
}
