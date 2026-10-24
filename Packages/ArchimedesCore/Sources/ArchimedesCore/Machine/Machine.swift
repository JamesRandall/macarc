import Foundation

/// Versioned description of an emulated machine.
public struct MachineConfiguration: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    public var version = MachineConfiguration.currentVersion
    public var model = MachineModel.a3000
    public var cpu = CPUType.arm2
    public var ramKB = 2048
    public var romPaths: [String] = []
    /// Optional persistent CMOS file (256 bytes). Not written automatically.
    public var cmosPath: String?
    /// Guest real-time clock start (Unix seconds); fixed for determinism.
    public var rtcEpoch: Int64 = 770_428_800
    /// Key codes held down from power-on (e.g. 0x34 Delete = CMOS reset).
    public var powerOnKeys: [UInt8] = []
    /// How long powerOnKeys are held, in guest milliseconds.
    public var powerOnKeysMs: Int = 4000
    public var floppyController = "WD1772"
    /// The monitor's name (a `MonitorType` raw value).
    public var monitor = "standard"
    public var monitorType: MonitorType {
        get { MonitorType(rawValue: monitor) ?? .standard }
        set { monitor = newValue.rawValue }
    }
    /// Hard disc image files, by drive number (nil: no drive fitted).
    public var hardDiscs: [String?] = []
    /// The Econet station number, with an Econet module fitted (nil: none).
    /// RISC OS reads it from CMOS byte 0, which is set to match.
    public var econetStation: Int?

    public init() {}

    /// A configuration for `model` with its usual processor and memory.
    public init(model: MachineModel) {
        self.model = model
        cpu = model.defaultCPU
        ramKB = model.defaultRAMKB
    }

    enum CodingKeys: String, CodingKey {
        case version, model, cpu, ramKB, romPaths, cmosPath, rtcEpoch, powerOnKeys, powerOnKeysMs, floppyController, monitor, hardDiscs, econetStation
    }

    // Fields added after version 1 are optional, so older snapshots load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        model = try c.decodeIfPresent(MachineModel.self, forKey: .model) ?? .a3000
        cpu = try c.decodeIfPresent(CPUType.self, forKey: .cpu) ?? .arm2
        ramKB = try c.decodeIfPresent(Int.self, forKey: .ramKB) ?? 2048
        romPaths = try c.decodeIfPresent([String].self, forKey: .romPaths) ?? []
        cmosPath = try c.decodeIfPresent(String.self, forKey: .cmosPath)
        rtcEpoch = try c.decodeIfPresent(Int64.self, forKey: .rtcEpoch) ?? 770_428_800
        powerOnKeys = try c.decodeIfPresent([UInt8].self, forKey: .powerOnKeys) ?? []
        powerOnKeysMs = try c.decodeIfPresent(Int.self, forKey: .powerOnKeysMs) ?? 4000
        floppyController = try c.decodeIfPresent(String.self, forKey: .floppyController) ?? "WD1772"
        monitor = try c.decodeIfPresent(String.self, forKey: .monitor) ?? "standard"
        hardDiscs = try c.decodeIfPresent([String?].self, forKey: .hardDiscs) ?? []
        econetStation = try c.decodeIfPresent(Int.self, forKey: .econetStation)
    }
}

public enum MachineError: Error, CustomStringConvertible {
    case noROM
    case rom(String)
    case badConfiguration(String)
    public var description: String {
        switch self {
        case .noROM: return "No RISC OS ROM configured. Supply a ROM image (file or directory)."
        case .rom(let s): return s
        case .badConfiguration(let s): return "Bad configuration: \(s)"
        }
    }
}

/// The complete A3000: ARM2 + MEMC + IOC + VIDC + WD1772 + keyboard + CMOS.
/// Not thread-safe: all calls must be serialised by the owner.
public final class Machine {
    public let configuration: MachineConfiguration
    public let rom: ROMImage
    public let memc: MEMC
    public let scheduler: Scheduler
    public let keyboard: Keyboard
    public let rtc: PCF8583
    public let ioc: IOC
    public let vidc: VIDC
    public let fdc: WD1772
    /// The ST506 controller on 400-series machines.
    public let hdc: HD63463?
    /// The 82C711 and IOEB of the A5000 family (its floppy controller
    /// replaces the WD1772, which then only holds the drives).
    public let superIO: SuperIO?
    /// The Econet module, when one's fitted.
    public let econet: EconetModule?

    /// Fitted hard disc images by drive, whichever controller has them.
    public var hardDiscImages: [HardDiscImage?] { hdc?.drives ?? superIO?.ide?.drives ?? [] }
    public let cpu: ARM2<MEMC>

    public private(set) var poweredOn = false
    public private(set) var resetCount = 0

    /// Scheduled input events (guest-time ordered).
    public struct InputEvent: Sendable {
        public enum Action: Sendable { case keyDown(UInt8), keyUp(UInt8), mouseMove(Int, Int) }
        public var tick: UInt64
        public var action: Action
        public init(tick: UInt64, action: Action) { self.tick = tick; self.action = action }
    }
    var inputQueue: [InputEvent] = []
    /// Nominal end of the last run. The CPU stops at the first instruction
    /// boundary at or after a target, so relative runs count from here rather
    /// than from the overshoot; otherwise splitting a run would shift time.
    var runTarget: UInt64 = 0

    // Diagnostics
    /// Watch writes to the physical RAM behind this logical range, resolved
    /// whenever runs start (so the watch follows the page once mapped).
    public var watchLogical: (UInt32, UInt32)?
    /// The system font found in the ROM, for reading the screen as text.
    var systemFont: [UInt64: Character]?
    /// The drive count was changed during this boot's CMOS reset.
    var cmosAdjusted = false
    public var swiCounts: [UInt32: UInt64] = [:]
    /// SWI numbers (X bit ignored) whose calls are logged with R0-R4 to `swiLog`.
    public var swiLogFilter: Set<UInt32> = []
    public var swiLog = RingBuffer<String>(capacity: 512)
    public var textOutput = RingBuffer<UInt8>(capacity: 8192)
    public var deviceLog = RingBuffer<String>(capacity: 256)
    public var recordSWIs = true

    public convenience init(configuration: MachineConfiguration) throws {
        guard !configuration.romPaths.isEmpty else { throw MachineError.noROM }
        let rom: ROMImage
        do { rom = try ROMImage.load(paths: configuration.romPaths) } catch { throw MachineError.rom("\(error)") }
        try self.init(configuration: configuration, rom: rom)
    }

    /// `hardDiscs`, when given, are already-open images to fit (by drive)
    /// instead of opening `configuration.hardDiscs`.
    public init(configuration: MachineConfiguration, rom: ROMImage, hardDiscs: [HardDiscImage?]? = nil) throws {
        let ramBytes = configuration.ramKB * 1024
        let model = configuration.model
        guard model.ramChoices.contains(configuration.ramKB) else {
            throw MachineError.badConfiguration("\(model.displayName) takes " + model.ramChoices.map { "\($0) KB" }.joined(separator: ", ") + " of RAM")
        }
        guard model.cpuChoices.contains(configuration.cpu) else {
            throw MachineError.badConfiguration("\(model.displayName) cannot be fitted with an \(configuration.cpu.rawValue)")
        }
        self.configuration = configuration
        self.rom = rom
        memc = MEMC(ramSize: ramBytes, rom: rom.data, memoryClockMHz: model.memoryClockMHz, slaveMEMCs: model == .a540)
        scheduler = Scheduler(bus: memc)
        keyboard = Keyboard()
        rtc = PCF8583(epochSeconds: configuration.rtcEpoch)
        ioc = IOC(bus: memc, scheduler: scheduler, keyboard: keyboard, rtc: rtc)
        vidc = VIDC(memc: memc, ioc: ioc, scheduler: scheduler)
        fdc = WD1772(scheduler: scheduler, ioc: ioc)
        cpu = ARM2(bus: memc)
        if configuration.cpu.isARM3 {
            let cache = ARM3Cache()
            cpu.fitARM3(cache: cache)
            memc.cache = cache
            memc.turboShift = configuration.cpu.turboShift
        }
        memc.io = ioc
        memc.vidc = vidc
        ioc.fdc = fdc
        // Hard disc images: the ones passed in, or opened from the configuration.
        var images = [HardDiscImage?](repeating: nil, count: model.hardDiscSlots)
        for i in images.indices {
            if let hardDiscs {
                images[i] = i < hardDiscs.count ? hardDiscs[i] : nil
            } else if i < configuration.hardDiscs.count, let path = configuration.hardDiscs[i] {
                images[i] = try HardDiscImage.open(path: path, sectorSize: model.hardDiscSectorSize)
            }
        }
        if model.hasST506 {
            let h = HD63463(scheduler: scheduler, ioc: ioc)
            h.drives = images
            ioc.hdc = h
            hdc = h
        } else {
            hdc = nil
        }
        if model.hasNewIO {
            let ide = model.hasIDE ? IDEController(scheduler: scheduler, ioc: ioc) : nil
            ide?.drives = images
            let s = SuperIO(fdc: FDC765(scheduler: scheduler, ioc: ioc, drives: fdc), ide: ide, vidc: vidc, joystickPorts: model == .a3010, monitor: configuration.monitorType)
            ioc.superIO = s
            superIO = s
        } else {
            superIO = nil
        }
        if let station = configuration.econetStation {
            guard (1...254).contains(station) else {
                throw MachineError.badConfiguration("Econet station numbers go from 1 to 254")
            }
            guard model.takesEconet else {
                throw MachineError.badConfiguration("The \(model.displayName) has no Econet header")
            }
            let e = EconetModule(station: UInt8(station), clock: { [unowned memc] in memc.ticks })
            e.onIRQ = { [unowned ioc] on in ioc.setFIQ(IOC.fiqEconet, on) }
            e.onReschedule = { [unowned scheduler] t in
                if t == .max { scheduler.cancel(.econet) } else { scheduler.schedule(.econet, at: t) }
            }
            ioc.econet = e
            econet = e
        } else {
            econet = nil
        }
        if configuration.cpu == .arm250 { cpu.hasSWP = true }
        let cpuRef = cpu
        ioc.updateLines = { irq, fiq in cpuRef.irqLine = irq; cpuRef.fiqLine = fiq }
        rtc.clockTicks = { [unowned memc] in memc.ticks }
        fdc.currentPC = { cpuRef.currentInstructionAddress }
        scheduler.setHandler(.input) { [unowned self] in self.processInput() }
        scheduler.setHandler(.econet) { [unowned self] in self.econet?.advance(to: self.memc.ticks) }
        cpu.swiObserver = { [unowned self] a, n in self.observeSWI(n, at: a) }
        let log: (String) -> Void = { [unowned self] s in self.deviceLog.append(s) }
        ioc.unknownAccess = log
        vidc.unknownWrite = log
        keyboard.log = log
        hdc?.log = log
        superIO?.ide?.log = log
        superIO?.fdc.log = log
        // A CMOS reset (Delete held at power-on) writes the default drive
        // count; the fitted hard discs are added as soon as it does, before
        // ADFS reads it.
        // The Econet station number is set the same way.
        if (model.hardDiscSlots > 0 || econet != nil) && !configuration.powerOnKeys.isEmpty {
            rtc.ramWritten = { [unowned self] a in
                guard self.ticks < MasterClock.ticks(milliseconds: 30_000) else { return }
                if a == Self.cmosDrives && self.configureHardDiscsInCMOS() { self.cmosAdjusted = true }
                if a == Self.cmosStation && self.configureStationInCMOS() { self.cmosAdjusted = true }
                // RISC OS then writes the checksum of what it set.
                if a == 63 && self.cmosAdjusted { self.updateCMOSChecksum() }
            }
        }
        vidc.frameCompleted = { [unowned self] _ in self.ioc.pumpKeyboard() }

        if let p = configuration.cmosPath, let d = FileManager.default.contents(atPath: p), d.count >= 240 {
            loadCMOS([UInt8](d))
        }
    }

    // MARK: Power / reset

    public func powerOn() {
        memc.ticks = 0
        runTarget = 0
        memc.reset()
        ioc.powerOn()
        vidc.powerOn()
        fdc.masterReset()
        hdc?.reset()
        superIO?.reset()
        econet?.reset(now: 0)
        configureHardDiscsInCMOS()
        configureStationInCMOS()
        cpu.reset()
        poweredOn = true
        rtc.epochTicks = 0
        for k in configuration.powerOnKeys { keyboard.keyDown(k) }
        if !configuration.powerOnKeys.isEmpty {
            // RISC OS clears memory before it reads the keyboard, so with
            // more than 4 MB keys must be held longer (measured on an A540:
            // under 5 s at 8 MB, under 8 s at 16 MB).
            let ms = max(configuration.powerOnKeysMs, configuration.ramKB > 4096 ? 2000 + configuration.ramKB / 2 : 0)
            let release = UInt64(ms) * 24_000
            for k in configuration.powerOnKeys { schedule(InputEvent(tick: release, action: .keyUp(k))) }
        }
    }

    /// Reset button: restarts the CPU and MEMC but keeps RAM, CMOS and media.
    public func reset() {
        resetCount += 1
        configureHardDiscsInCMOS()
        configureStationInCMOS()
        memc.reset()
        ioc.reset()
        fdc.masterReset()
        hdc?.reset()
        superIO?.reset()
        econet?.reset(now: memc.ticks)
        cpu.reset()
    }

    // MARK: Execution

    public var ticks: UInt64 { memc.ticks }
    /// Nominal guest time reached by the last run (excludes instruction
    /// overshoot, which is at most one instruction plus DMA); script times
    /// relative to "now" should count from this. Ticks advanced by other
    /// means (single-stepping) move it forward.
    public var nominalTicks: UInt64 { memc.ticks <= runTarget &+ 24_000 ? runTarget : memc.ticks }
    public var seconds: Double { Double(memc.ticks) / Double(MasterClock.ticksPerSecond) }

    public enum StopReason: Equatable, Sendable {
        case completed
        /// The debugger has stopped the machine (see `debugger.stopReason`).
        case stopped
        case instructionBudget
        case frameLimit
    }

    // MARK: Debugger

    private var _debugger: Debugger?
    /// The debugger, created when first used.
    public var debugger: Debugger {
        if let d = _debugger { return d }
        let d = Debugger(machine: self)
        _debugger = d
        cpu.debugger = d
        return d
    }
    /// The debugger if anything has used it (so checks don't create one).
    public var debuggerIfCreated: Debugger? { _debugger }
    /// Runs return at once while the debugger holds the machine stopped.
    public var isStoppedByDebugger: Bool { _debugger?.isStopped ?? false }

    /// Run until the guest clock reaches `target` ticks.
    @discardableResult
    public func run(untilTick target: UInt64, maxInstructions: UInt64 = .max) -> StopReason {
        if !poweredOn { powerOn() }
        if isStoppedByDebugger { return .stopped }
        runTarget = target
        var remaining = maxInstructions
        while memc.ticks < target {
            if let (a, n) = watchLogical, let p = memc.debugTranslate(a) { memc.writeWatch = p...(p + n - 1) }
            scheduler.dispatch()
            memc.stopAt = min(target, scheduler.next)
            if memc.ticks >= memc.stopAt { continue }
            let before = cpu.instructionCount
            let r = cpu.run(maxInstructions: remaining)
            let done = cpu.instructionCount &- before
            if remaining != .max { remaining = remaining > done ? remaining - done : 0 }
            switch r {
            // Stopped early: time now runs on from here, not from the target.
            case .debugger: runTarget = memc.ticks; return .stopped
            case .budget: runTarget = memc.ticks; return .instructionBudget
            case .none: break
            }
            if remaining == 0 { runTarget = memc.ticks; return .instructionBudget }
        }
        scheduler.dispatch()
        return .completed
    }

    @discardableResult
    public func run(ticks n: UInt64) -> StopReason {
        // Count from the nominal end of the last run, not the overshoot.
        return run(untilTick: nominalTicks &+ n)
    }

    @discardableResult
    public func run(seconds s: Double) -> StopReason { run(ticks: UInt64(s * Double(MasterClock.ticksPerSecond))) }

    /// Run until `n` more video frames have completed (bounded by `maxSeconds` guest time).
    @discardableResult
    public func runFrames(_ n: Int, maxSeconds: Double = 10) -> StopReason {
        let target = vidc.frameCount &+ UInt64(n)
        let limit = memc.ticks &+ UInt64(maxSeconds * Double(MasterClock.ticksPerSecond))
        while vidc.frameCount < target {
            if memc.ticks >= limit { return .frameLimit }
            let r = run(untilTick: min(limit, memc.ticks &+ 24_000))
            if r != .completed { return r }
        }
        return .completed
    }

    /// Executes `n` instructions (stepping into interrupts), as the
    /// debugger's Step Into does.
    @discardableResult
    public func step(_ n: Int = 1) -> StopReason {
        if !poweredOn { powerOn() }
        for _ in 0..<n {
            _ = debugger.run(.stepInstruction, maxTicks: MasterClock.ticksPerSecond) { self.run(ticks: $0) }
        }
        return isStoppedByDebugger ? .stopped : .completed
    }

    // MARK: Input

    public func keyDown(_ code: UInt8) { inputRecorder?(InputEvent(tick: ticks, action: .keyDown(code))); keyboard.keyDown(code); ioc.pumpKeyboard() }
    public func keyUp(_ code: UInt8) { inputRecorder?(InputEvent(tick: ticks, action: .keyUp(code))); keyboard.keyUp(code); ioc.pumpKeyboard() }
    public func mouseMove(dx: Int, dy: Int) { inputRecorder?(InputEvent(tick: ticks, action: .mouseMove(dx, dy))); keyboard.mouseMove(dx: dx, dy: dy); ioc.pumpKeyboard() }

    /// Told of every live input (key, button, mouse movement) as it arrives,
    /// so a rewind can replay it on the same tick.
    public var inputRecorder: ((InputEvent) -> Void)?

    /// After stopping on an instruction count: deliver what is due on this
    /// tick and enter a pending interrupt, as the next run would before the
    /// instruction, so the PC shows where execution really goes next.
    func settleBeforeInstruction() {
        scheduler.dispatch()
        if let v = cpu.takeInterrupt() { debuggerIfCreated?.interruptTaken(v == .fiq ? "FIQ" : "IRQ") }
    }

    /// Queues recorded inputs to arrive on their ticks (rewind replay).
    func replay(_ events: [InputEvent]) { for e in events { schedule(e) } }

    /// Queue an input event at an absolute guest tick (reproducible scripts).
    public func schedule(_ e: InputEvent) {
        inputQueue.append(e)
        inputQueue.sort { $0.tick < $1.tick }
        scheduler.schedule(.input, at: max(inputQueue[0].tick, memc.ticks))
    }

    /// Type a string with key down/up events spaced `intervalMs` apart.
    public func scheduleTyping(_ text: String, startingAt tick: UInt64? = nil, intervalMs: Int = 60) {
        var t = tick ?? memc.ticks &+ 24_000
        let step = UInt64(intervalMs) * 24_000
        for ch in text {
            guard let (code, shift) = ArcKey.forCharacter(ch) else { continue }
            if shift { schedule(InputEvent(tick: t, action: .keyDown(0x4C))); t += step / 2 }
            schedule(InputEvent(tick: t, action: .keyDown(code))); t += step
            schedule(InputEvent(tick: t, action: .keyUp(code))); t += step / 2
            if shift { schedule(InputEvent(tick: t, action: .keyUp(0x4C))); t += step / 2 }
        }
    }

    public var pendingInputEvents: Int { inputQueue.count }

    /// The blocking read SWI (OS_ReadC, OS_ReadLine, Wimp_Poll)
    /// last called, and the mode it was called from.
    var blockingRead: (swi: UInt32, callerMode: UInt32)?
    /// Whether that read is the Wimp's (Wimp_Poll) rather than a prompt's.
    public var blockingReadIsWimp: Bool { blockingRead?.swi == 0x400C7 }
    /// OS_Byte 129 (INKEY) calls: programs polling the keyboard.
    public private(set) var keyboardPolls: UInt64 = 0

    /// Whether the CPU is inside a blocking read now: in the SWI (not back in
    /// the caller's mode). Interrupt handlers don't count either way (nil).
    public func insideBlockingRead() -> Bool? {
        let mode = cpu.psr & 3
        if mode == 1 || mode == 2 { return nil }
        guard let w = blockingRead else { return false }
        if mode == w.callerMode { blockingRead = nil; return false }
        return true
    }

    /// A floppy motor running or a hard disc command in progress.
    public var discsBusy: Bool {
        if let sio = superIO { if sio.fdc.motorOn || sio.fdc.job != .none || (sio.ide?.status ?? 0) & 0x80 != 0 { return true } }
        else if fdc.motorOn || fdc.busy { return true }
        if let h = hdc, h.status & 0x80 != 0 || h.dataRequest { return true }
        return false
    }

    func processInput() {
        while let e = inputQueue.first, e.tick <= memc.ticks {
            inputQueue.removeFirst()
            switch e.action {
            case .keyDown(let k): keyboard.keyDown(k)
            case .keyUp(let k): keyboard.keyUp(k)
            case .mouseMove(let x, let y): keyboard.mouseMove(dx: x, dy: y)
            }
        }
        ioc.pumpKeyboard()
        if let next = inputQueue.first { scheduler.schedule(.input, at: next.tick) }
    }

    // MARK: Media

    public func insertFloppy(_ image: FloppyImage, drive: Int = 0) {
        fdc.drives[drive].disc = image
        deviceLog.append("floppy \(drive): inserted \(image.sourcePath ?? "image") \(image.geometry.formatName) sha256=\(image.sha256.prefix(16))")
    }

    public func ejectFloppy(drive: Int = 0) {
        fdc.drives[drive].disc = nil
        deviceLog.append("floppy \(drive): ejected")
    }

    // MARK: CMOS

    public var cmos: [UInt8] { rtc.ram }

    public func loadCMOS(_ data: [UInt8]) {
        for i in 0..<min(256, data.count) { rtc.ram[i] = data[i] }
    }

    /// RTC RAM byte holding the configured drive counts: floppies in bits
    /// 0-2, ST506 hard discs in bits 3-5 (`*Configure HardDiscs`), IDE
    /// discs in bits 6-7 (`*Configure IDEDiscs`).
    static let cmosDrives = 199

    var hardDiscShift: Int { configuration.model.hasIDE ? 6 : 3 }
    var hardDiscMask: UInt8 { configuration.model.hasIDE ? 0xC0 : 0x38 }

    /// Hard discs RISC OS is configured to look for (of this machine's kind).
    public var configuredHardDiscs: Int { Int((rtc.ram[Self.cmosDrives] & hardDiscMask) >> UInt8(hardDiscShift)) }

    /// The drives are fitted from the Mac side, so at power-on and reset
    /// the configured count is made to match them (as the owner would with
    /// *Configure): RISC OS must look for a fitted drive, and one configured
    /// but absent makes ADFS wait on it at start-up (about 40 s) and leaves a
    /// drive icon that only gives errors. Machines with no hard disc
    /// interface are left alone. Returns whether the byte changed.
    @discardableResult
    func configureHardDiscsInCMOS() -> Bool {
        guard configuration.model.hardDiscSlots > 0 else { return false }
        let wanted = (hardDiscImages.lastIndex(where: { $0 != nil }) ?? -1) + 1
        guard configuredHardDiscs != wanted else { return false }
        rtc.ram[Self.cmosDrives] = (rtc.ram[Self.cmosDrives] & ~hardDiscMask) | UInt8(wanted << hardDiscShift)
        updateCMOSChecksum()
        return true
    }

    /// RTC RAM byte holding the Econet station number (CMOS byte 0: RISC
    /// OS's bytes 0-191 are at &40 onwards).
    static let cmosStation = 0x40

    /// With Econet fitted, the station number in CMOS is the network's, as
    /// the owner would set it with SetStation. Returns whether it changed.
    @discardableResult
    func configureStationInCMOS() -> Bool {
        guard let e = econet, rtc.ram[Self.cmosStation] != e.station else { return false }
        rtc.ram[Self.cmosStation] = e.station
        updateCMOSChecksum()
        return true
    }

    /// RISC OS 3 checks byte 63 against the other configuration bytes
    /// (16-62, 64-255) summed, plus one; RISC OS 2 ignores it.
    func updateCMOSChecksum() {
        var sum = 1
        for i in 16..<256 where i != 63 { sum += Int(rtc.ram[i]) }
        rtc.ram[63] = UInt8(sum & 0xFF)
    }

    /// A CMOS image RISC OS has never set up: fewer than eight
    /// configuration bytes set, besides the clock (0-15), the checksum (63)
    /// and the drive counts MacArch writes (199). A reset sets dozens.
    public static func cmosNeverConfigured(_ d: [UInt8]) -> Bool {
        (16..<min(256, d.count)).filter { $0 != 63 && $0 != cmosDrives && d[$0] != 0 }.count < 8
    }

    public func saveCMOS(to path: String) throws {
        try Data(rtc.ram).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Diagnostics

    func observeSWI(_ n: UInt32, at address: UInt32) {
        guard recordSWIs else { return }
        let num = n & ~0x20000 // ignore the X bit
        swiCounts[num, default: 0] &+= 1
        if swiLogFilter.contains(num) {
            swiLog.append(String(format: "t=%.3f pc=%08X SWI &%X r0=%08X r1=%08X r2=%08X r3=%08X r4=%08X",
                                 seconds, address, num, cpu.r[0], cpu.r[1], cpu.r[2], cpu.r[3], cpu.r[4]))
        }
        // Reading the keyboard or waiting in the Wimp: the call blocks until
        // there's input, so being inside it means waiting for input.
        // Only calls from user mode count: OS_ReadLine itself calls OS_ReadC
        // from supervisor mode for each character.
        // Wimp_PollIdle is a timed wait (the desktop's start-up splash uses
        // it), so it doesn't count.
        if cpu.psr & 3 == 0, [0x04, 0x0E, 0x400C7].contains(num) { blockingRead = (num, 0) }
        if num == 0x400E1 { blockingRead = nil }
        if num == 0x06 && cpu.r[0] == 129 { keyboardPolls &+= 1 }
        // OS_WriteI's handler prints with OS_WriteC: that character is
        // captured once.
        let writeI = pendingWriteI
        pendingWriteI = nil
        switch num {
        case 0x00: // OS_WriteC
            let c = UInt8(truncatingIfNeeded: cpu.r[0])
            if !(writeI == c && cpu.psr & 3 == 3) { textOutput.append(c) }
        case 0x100...0x1FF: // OS_WriteI
            textOutput.append(UInt8(num - 0x100))
            pendingWriteI = UInt8(num - 0x100)
        case 0x01: // OS_WriteS: string follows the SWI instruction
            var a = address &+ 4
            for _ in 0..<256 {
                guard let b = memc.debugRead(a, space: .logical), b != 0 else { break }
                textOutput.append(b); a &+= 1
            }
        case 0x46: // OS_WriteN: R1 bytes from R0
            var a = cpu.r[0]
            for _ in 0..<min(Int(cpu.r[1]), 256) {
                guard let b = memc.debugRead(a, space: .logical) else { break }
                textOutput.append(b); a &+= 1
            }
        case 0x02: // OS_Write0
            var a = cpu.r[0]
            for _ in 0..<256 {
                guard let b = memc.debugRead(a, space: .logical), b != 0 else { break }
                textOutput.append(b); a &+= 1
            }
        default: break
        }
    }

    /// The character of the OS_WriteI just called, until the next SWI.
    var pendingWriteI: UInt8?

    /// Printable rendering of recent OS text output (VDU stream, control codes removed).
    public var recentText: String {
        var s = ""
        for b in textOutput.elements {
            if b == 10 || b == 13 { if !s.hasSuffix("\n") { s.append("\n") } } else if b >= 32 && b < 127 { s.append(Character(UnicodeScalar(b))) }
        }
        return s
    }

    public var currentFrame: VideoFrame { vidc.lastFrame }
}

// MARK: - Snapshot state

extension Machine {
    func saveMachineState(_ w: inout StateWriter) {
        w.bool(poweredOn)
        w.i64(resetCount)
        w.u64(runTarget)
        w.u32(UInt32(inputQueue.count))
        for e in inputQueue {
            w.u64(e.tick)
            switch e.action {
            case .keyDown(let k): w.u8(0); w.u8(k)
            case .keyUp(let k): w.u8(1); w.u8(k)
            case .mouseMove(let x, let y): w.u8(2); w.i64(x); w.i64(y)
            }
        }
    }

    func loadMachineState(_ r: inout StateReader) throws {
        poweredOn = try r.bool()
        resetCount = try r.i64()
        runTarget = try r.u64()
        let n = Int(try r.u32())
        guard n < 1 << 20 else { throw SnapshotError.corrupt("input queue length \(n)") }
        inputQueue = try (0..<n).map { _ in
            let t = try r.u64()
            switch try r.u8() {
            case 0: return InputEvent(tick: t, action: .keyDown(try r.u8()))
            case 1: return InputEvent(tick: t, action: .keyUp(try r.u8()))
            case 2: return InputEvent(tick: t, action: .mouseMove(try r.i64(), try r.i64()))
            default: throw SnapshotError.corrupt("input event kind")
            }
        }
    }
}

// MARK: - Indicator lights

extension Machine {
    /// The A3000's keyboard LEDs and floppy drive light.
    public struct Lights: Equatable, Sendable {
        public var capsLock = false
        public var numLock = false
        public var scrollLock = false
        public var drive = false
        public init() {}
    }

    public var lights: Lights {
        var l = Lights()
        // Keyboard LED command bits: 0 Caps Lock, 1 Num Lock, 2 Scroll Lock.
        l.capsLock = keyboard.leds & 1 != 0
        l.numLock = keyboard.leds & 2 != 0
        l.scrollLock = keyboard.leds & 4 != 0
        l.drive = superIO?.fdc.light(drive: 0) ?? fdc.light(drive: 0)
        return l
    }
}
