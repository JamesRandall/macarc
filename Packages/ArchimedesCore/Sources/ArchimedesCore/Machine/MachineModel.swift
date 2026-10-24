/// The Archimedes models MacArch emulates and what each one fits.
///
/// Raw values are what `MachineConfiguration` stores (and what snapshots
/// written before models existed recorded: "A3000").
public enum MachineModel: String, CaseIterable, Codable, Sendable {
    case a305 = "A305"
    case a310 = "A310"
    case a3000 = "A3000"
    case a410 = "A410/1"
    case a420 = "A420/1"
    case a440 = "A440/1"
    case a540 = "A540"
    case a5000 = "A5000"
    case a3010 = "A3010"
    case a3020 = "A3020"
    case a4000 = "A4000"

    public var displayName: String {
        switch self {
        case .a305: "Acorn Archimedes 305"
        case .a310: "Acorn Archimedes 310"
        case .a3000: "Acorn A3000"
        case .a410: "Acorn Archimedes 410/1"
        case .a420: "Acorn Archimedes 420/1"
        case .a440: "Acorn Archimedes 440/1"
        case .a540: "Acorn Archimedes 540"
        case .a5000: "Acorn A5000"
        case .a3010: "Acorn A3010"
        case .a3020: "Acorn A3020"
        case .a4000: "Acorn A4000"
        }
    }

    /// The A5000 family replaced the WD1772 and the backplane latches with
    /// an 82C711 (765-style floppy controller, IDE, serial, parallel) and
    /// the IOEB.
    public var hasNewIO: Bool { [.a5000, .a3010, .a3020, .a4000].contains(self) }

    /// Monitors the machine can tell apart. The IOEB machines read the
    /// monitor's ID lines; the others assume a standard monitor unless
    /// RISC OS is configured otherwise (*Configure MonitorType).
    public var monitorChoices: [MonitorType] { hasNewIO ? MonitorType.allCases : [.standard] }

    /// IDE interface (in the 82C711) with a drive bay.
    public var hasIDE: Bool { [.a5000, .a3020, .a4000].contains(self) }

    /// Memory sizes a buyer could have (KB). The 300 and 400 series and the
    /// A3000 take up to 4 MB on one MEMC; the A540 adds slave MEMCs.
    public var ramChoices: [Int] {
        switch self {
        case .a305, .a310, .a3000: [512, 1024, 2048, 4096]
        case .a410, .a420, .a440: [1024, 2048, 4096]
        case .a540: [4096, 8192, 16384]
        case .a5000, .a3010: [1024, 2048, 4096]
        case .a3020, .a4000: [2048, 4096]
        }
    }

    public var defaultRAMKB: Int {
        switch self {
        case .a305: 512
        case .a310, .a410: 1024
        case .a3000, .a420, .a5000, .a3020, .a4000: 2048
        case .a440, .a540: 4096
        case .a3010: 1024
        }
    }

    /// Processors that fit: the ARM2 machines took third-party ARM3 cards.
    public var cpuChoices: [CPUType] {
        switch self {
        case .a540, .a5000: [.arm3, .arm3x2, .arm3x4]
        case .a3010, .a3020, .a4000: [.arm250]
        default: [.arm2, .arm3, .arm3x2, .arm3x4]
        }
    }

    /// What Acorn fitted: an ARM2 where there's a choice, else the first.
    public var defaultCPU: CPUType { cpuChoices.contains(.arm2) ? .arm2 : cpuChoices[0] }

    /// The 400 series has an HD63463 ST506 controller on the I/O backplane.
    public var hasST506: Bool { self == .a410 || self == .a420 || self == .a440 }

    /// Hard disc drives the built-in controller can take.
    public var hardDiscSlots: Int { hasST506 || hasIDE ? 2 : 0 }

    /// Sector size of the built-in hard disc interface.
    public var hardDiscSectorSize: Int { hasIDE ? 512 : 256 }

    /// DRAM cycle rate: 8 MHz MEMC1a, 12 MHz on the A540 and the A5000 family.
    public var memoryClockMHz: Int { self == .a540 || hasNewIO ? 12 : 8 }
}

public enum CPUType: String, CaseIterable, Codable, Sendable {
    case arm2 = "ARM2"
    case arm3 = "ARM3"
    case arm250 = "ARM250"
    /// Faster than any real ARM3, for games that wanted a RiscPC: only the
    /// processor speeds up; see `MEMC.turboShift`.
    case arm3x2 = "ARM3x2"
    case arm3x4 = "ARM3x4"

    /// An ARM3 (with its cache), at any speed.
    public var isARM3: Bool { self == .arm3 || self == .arm3x2 || self == .arm3x4 }
    public var turboShift: UInt64 { self == .arm3x2 ? 1 : self == .arm3x4 ? 2 : 0 }

    public var displayName: String {
        switch self {
        case .arm2: "ARM2 (8 MHz)"
        case .arm3: "ARM3 (24 MHz, 4 KB cache)"
        case .arm250: "ARM250 (12 MHz)"
        case .arm3x2: "ARM3 ×2 (48 MHz, faster than real)"
        case .arm3x4: "ARM3 ×4 (96 MHz, faster than real)"
        }
    }
}

/// The monitor plugged into the video socket.
public enum MonitorType: String, CaseIterable, Codable, Sendable {
    /// 15 kHz TV-rate colour monitor (Acorn AKF11/AKF12 and similar).
    case standard
    /// Multiscan monitor (Acorn AKF18 and similar): 15 kHz modes and VGA/SVGA.
    case multisync
    /// Fixed 31 kHz colour VGA monitor.
    case vga

    public var displayName: String {
        switch self {
        case .standard: "Standard (15 kHz)"
        case .multisync: "Multisync"
        case .vga: "VGA"
        }
    }
}
