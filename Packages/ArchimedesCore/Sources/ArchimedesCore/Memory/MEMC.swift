/// Acorn MEMC (VL86C110) memory controller: address decoding, logical to
/// physical translation (CAM), page protection, ROM overlay at reset and
/// the DMA address generators used by VIDC.
///
/// Address map (26-bit):
///   0000000-1FFFFFF  logically mapped RAM (translated through the CAM)
///   2000000-2FFFFFF  physically mapped RAM (supervisor only)
///   3000000-33FFFFF  I/O (IOC and its peripherals; supervisor only)
///   3400000-37FFFFF  read: low ROM; write: VIDC (34/35) or MEMC DMA/control (36/37)
///   3800000-3FFFFFF  read: high ROM (RISC OS); write: address translator (CAM)
import Foundation

public final class MEMC: ARMBus {
    public var ticks: UInt64 = 0
    public var stopAt: UInt64 = 0
    public var abort = false
    public var privileged = true {
        didSet { updateLevels() }
    }

    public let ramSize: Int
    public let ram: UnsafeMutablePointer<UInt8>
    let ramMask: Int
    public let romSize: Int
    public let rom: UnsafeMutablePointer<UInt8>
    let romMask: Int

    /// Logical 4 KB page -> descriptor. Bits 0-23 physical byte offset,
    /// 24-25 PPL, bit 26 valid.
    let pageTable: UnsafeMutablePointer<UInt32>
    /// Raw CAM write addresses, indexed by physical page number (or 0xFFFFFFFF).
    /// 128 per MEMC: the master's first, then each slave's.
    var camEntries: [UInt32]
    /// The A540's arrangement: a master MEMC and up to three slaves, each
    /// with its own 4 MB and its own 128-entry CAM. MEMC's databook (VLSI
    /// VL86C110: "Dual MEMC Systems") has A7 choose between master and
    /// slave translators when they're programmed; the A540's decoding PAL
    /// extends that to four with A7 and A12, whatever the page size (it
    /// can't know it). A physical address's bits 22 and 23 choose which
    /// MEMC's DRAM answers. A CAM write for a MEMC that isn't fitted is
    /// lost. A physical read with no MEMC behind it reads &FF, as
    /// Arculator has it (nothing drives the data bus; the hardware
    /// references don't say). Lookups compare every MEMC's entries and the
    /// MEMCs' aborts are ANDed, so a logical page aborts only when no MEMC
    /// maps it. Other machines have one MEMC, which ignores those bits, so
    /// their physical space repeats every 4 MB or less.
    public let slaveMEMCs: Bool
    /// MEMCs fitted (1 to 4).
    public let memcCount: Int
    /// Write order of each CAM entry; the most recent match wins.
    var camSequence: [UInt64]
    var camCounter: UInt64 = 0
    /// Physical pages with a logical address, and how many there are.
    public var mappedPages: (mapped: Int, total: Int) { (camEntries.filter { $0 != .max }.count, camEntries.count) }

    // Control register
    public private(set) var pageSizeCode: UInt32 = 0
    public private(set) var lowROMSpeed: UInt32 = 0
    public private(set) var highROMSpeed: UInt32 = 0
    public private(set) var refreshControl: UInt32 = 0
    public private(set) var videoDMAEnabled = false
    public private(set) var soundDMAEnabled = false
    public private(set) var osMode = false
    var highROMTicks: UInt64 = 12

    /// After reset ROM is mapped over the whole address space for reads
    /// until an address with A25 set is accessed.
    public private(set) var romOverlay = true

    // DMA address generators (byte addresses within physical RAM).
    public private(set) var vinit: UInt32 = 0
    public private(set) var vstart: UInt32 = 0
    public private(set) var vend: UInt32 = 0
    public private(set) var cinit: UInt32 = 0
    public private(set) var sstart: UInt32 = 0
    public private(set) var sendNext: UInt32 = 0
    public private(set) var sendCurrent: UInt32 = 0
    public private(set) var sptr: UInt32 = 0
    /// Recent writes to the sound DMA registers (diagnostics).
    public var soundRegisterLog = RingBuffer<String>(capacity: 64)
    var nextSoundBufferValid = false
    public var vptr: UInt32 = 0
    public var cptr: UInt32 = 0

    var readLevel: UInt32 = 3
    var writeLevel: UInt32 = 3

    unowned(unsafe) var io: IOC!
    unowned(unsafe) var vidc: VIDC!

    /// Debug watchpoints on physical RAM writes (byte offsets). Checked only when non-empty.
    public var writeWatch: ClosedRange<UInt32>?
    public var watchHit: ((UInt32, UInt32) -> Void)?

    /// DRAM cycle costs in master clock ticks (8 MHz: 3 and 6; 12 MHz: 2 and 4).
    public let sCycle: UInt64
    public let nCycle: UInt64
    /// The ARM3 cache when one is fitted; `cacheOn` mirrors its enable bit.
    public var cache: ARM3Cache? { didSet { cacheControlChanged() } }
    var cacheOn = false

    public init(ramSize: Int, rom: [UInt8], memoryClockMHz: Int = 8, slaveMEMCs: Bool = false) {
        precondition(ramSize.nonzeroBitCount == 1, "RAM size must be a power of two")
        self.ramSize = ramSize
        self.slaveMEMCs = slaveMEMCs
        memcCount = slaveMEMCs ? max(1, ramSize >> 22) : 1
        sCycle = UInt64(24 / memoryClockMHz)
        nCycle = 2 * sCycle
        let pages = 128 * memcCount
        camEntries = [UInt32](repeating: .max, count: pages)
        camSequence = [UInt64](repeating: 0, count: pages)
        iCycle = sCycle
        ram = .allocate(capacity: ramSize)
        ram.initialize(repeating: 0, count: ramSize)
        ramMask = ramSize - 1
        // ROM area is 8 MB; images are mirrored to the next power of two.
        var size = 1
        while size < max(rom.count, 4) { size <<= 1 }
        romSize = size
        let romBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        romBuffer.initialize(repeating: 0xFF, count: size)
        for i in 0..<rom.count { romBuffer[i] = rom[i] }
        self.rom = romBuffer
        romMask = size - 1
        pageTable = .allocate(capacity: 8192)
        pageTable.initialize(repeating: 0, count: 8192)
    }

    deinit {
        ram.deallocate(); rom.deallocate(); pageTable.deallocate()
    }

    public func reset() {
        cache?.reset()
        cacheControlChanged()
        romOverlay = true
        privileged = true
        osMode = false
        soundDMAEnabled = false
        videoDMAEnabled = false
        setPageSize(0)
        lowROMSpeed = 0; highROMSpeed = 0; highROMTicks = 12
        nextSoundBufferValid = false
    }

    func updateLevels() {
        if privileged { readLevel = 3; writeLevel = 3 } else if osMode { readLevel = 3; writeLevel = 1 } else { readLevel = 1; writeLevel = 0 }
    }

    // MARK: - CPU accesses

    @inline(__always) func ramWordPointer(_ offset: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(ram + (offset & ramMask & ~3))
    }

    @inline(__always) func romWord(_ address: UInt32) -> UInt32 {
        UnsafeRawPointer(rom + (Int(address) & romMask & ~3)).load(as: UInt32.self)
    }

    @inline(__always) func translate(_ address: UInt32, write: Bool) -> Int {
        let e = pageTable[Int((address >> 12) & 0x1FFF)]
        if e & 0x0400_0000 == 0 { return -1 }
        let ppl = (e >> 24) & 3
        if ppl > (write ? writeLevel : readLevel) { return -1 }
        return Int(e & 0x00FF_FFFF) | Int(address & 0xFFF)
    }

    @inline(__always)
    public func fetch(_ address: UInt32, sequential: Bool) -> UInt32 {
        readWord(address, sequential: sequential)
    }

    @inline(__always)
    public func readWord(_ address: UInt32, sequential: Bool) -> UInt32 {
        if cacheOn { return readWordCached(address, sequential: sequential) }
        return readWordMemory(address, sequential: sequential)
    }

    @inline(__always)
    func readWordMemory(_ address: UInt32, sequential: Bool) -> UInt32 {
        if romOverlay {
            romOverlay = address & 0x0200_0000 == 0
            if romOverlay { ticks &+= highROMTicks; return romWord(address) }
        }
        let a = address & 0x03FF_FFFF
        if a < 0x0200_0000 {
            ticks &+= sequential ? sCycle : nCycle
            let p = translate(a, write: false)
            if p < 0 { abort = true; return 0 }
            return ramWordPointer(p).load(as: UInt32.self)
        }
        if a >= 0x0380_0000 {
            ticks &+= highROMTicks
            return romWord(a)
        }
        return readWordSlow(a, sequential: sequential)
    }

    func readWordSlow(_ a: UInt32, sequential: Bool) -> UInt32 {
        if a < 0x0300_0000 {
            ticks &+= sequential ? sCycle : nCycle
            if !privileged { abort = true; return 0 }
            guard physicalFitted(a) else { return 0xFFFF_FFFF }
            return ramWordPointer(physicalOffset(a)).load(as: UInt32.self)
        }
        if a < 0x0340_0000 {
            if !privileged { abort = true; return 0 }
            return io.read(a)
        }
        // Low ROM: no expansion ROMs fitted on A3000.
        ticks &+= 12
        return 0
    }

    public func readByte(_ address: UInt32) -> UInt32 {
        if cacheOn { return readByteCached(address) }
        return readByteMemory(address)
    }

    func readByteMemory(_ address: UInt32) -> UInt32 {
        if romOverlay {
            romOverlay = address & 0x0200_0000 == 0
            if romOverlay { ticks &+= highROMTicks; return UInt32(rom[Int(address) & romMask]) }
        }
        let a = address & 0x03FF_FFFF
        if a < 0x0200_0000 {
            ticks &+= nCycle
            let p = translate(a, write: false)
            if p < 0 { abort = true; return 0 }
            return UInt32(ram[p & ramMask])
        }
        if a >= 0x0380_0000 {
            ticks &+= highROMTicks
            return UInt32(rom[Int(a) & romMask])
        }
        if a < 0x0300_0000 {
            ticks &+= nCycle
            if !privileged { abort = true; return 0 }
            guard physicalFitted(a) else { return 0xFF }
            return UInt32(ram[physicalOffset(a)])
        }
        if a < 0x0340_0000 {
            if !privileged { abort = true; return 0 }
            return io.read(a) & 0xFF
        }
        ticks &+= 12
        return 0
    }

    @inline(__always)
    public func writeWord(_ address: UInt32, _ value: UInt32, sequential: Bool) {
        let a = address & 0x03FF_FFFF
        if cacheOn { noteWrite(a) }
        if a < 0x0200_0000 {
            ticks &+= sequential ? sCycle : nCycle
            let p = translate(a, write: true)
            if p < 0 { abort = true; return }
            if writeWatch != nil { checkWatch(UInt32(p & ramMask), value) }
            ramWordPointer(p).storeBytes(of: value, as: UInt32.self)
            return
        }
        writeSlow(a, value, sequential: sequential, byte: false)
    }

    public func writeByte(_ address: UInt32, _ value: UInt8) {
        let a = address & 0x03FF_FFFF
        if cacheOn { noteWrite(a) }
        if a < 0x0200_0000 {
            ticks &+= nCycle
            let p = translate(a, write: true)
            if p < 0 { abort = true; return }
            if writeWatch != nil { checkWatch(UInt32(p & ramMask), UInt32(value)) }
            ram[p & ramMask] = value
            return
        }
        // The ARM2 drives a byte store onto all four byte lanes.
        writeSlow(a, UInt32(value) &* 0x0101_0101, sequential: false, byte: true)
    }

    /// Whether a MEMC answers a physical RAM address (always, without slaves).
    @inline(__always) func physicalFitted(_ a: UInt32) -> Bool {
        !slaveMEMCs || Int((a >> 22) & 3) < memcCount
    }

    /// Where a physically addressed access lands in RAM.
    @inline(__always) func physicalOffset(_ a: UInt32) -> Int {
        let offset = Int(a & 0x00FF_FFFF)
        return (pageSizeCode == dramPageSizeCode ? offset : dramOffset(offset)) & ramMask
    }

    /// The page size that matches the fitted DRAM: 512 KB uses 4 KB pages,
    /// up to 4 MB with 32 KB pages (always 128 physical pages).
    var dramPageSizeCode: UInt32 { UInt32(max(0, min(3, (ramSize >> 19).trailingZeroBitCount))) }

    /// MEMC multiplexes physical address bits onto the DRAM row and column
    /// lines differently for each page size, and the fitted chips are wired
    /// for the page size that matches them. When software selects another
    /// page size (as RISC OS does while sizing memory) addresses alias in a
    /// way the sizing code relies on. Only five DRAM lines move: row 8 and 9
    /// and column 2, 3 and 9; every other address bit passes straight through.
    func dramOffset(_ offset: Int) -> Int {
        // Physical address bit carrying each moving line, per page size
        // (-1: that line is not driven at this page size).
        //                           r8  r9  c2  c3  c9
        let wiring: [[Int]] = [[-1, -1, 12, 13, -1],   // 4 KB
                               [12, -1, 19, 13, -1],   // 8 KB
                               [12, -1, 19, 13, 20],   // 16 KB
                               [12, 13, 19, 21, 20]]   // 32 KB
        let from = wiring[Int(pageSizeCode)], to = wiring[Int(dramPageSizeCode)]
        var result = offset & ~(1 << 12 | 1 << 13 | 1 << 19 | 1 << 20 | 1 << 21)
        for line in 0..<5 where from[line] >= 0 && to[line] >= 0 {
            result |= ((offset >> from[line]) & 1) << to[line]
        }
        return result
    }

    // MARK: - ARM3 cache timing

    /// Ticks per I cycle: the ARM3 runs from its own clock once its cache is
    /// on; otherwise the processor is clocked at the memory rate.
    public private(set) var iCycle: UInt64 = MasterClock.iCycle

    public func cacheControlChanged() {
        cacheOn = cache?.enabled ?? false
        iCycle = cacheOn ? 1 : sCycle
    }

    /// A faster ARM3 than Acorn fitted (2^`turboShift` times 24 MHz):
    /// cycles at the processor clock (cache hits and internal cycles, with
    /// the cache on) cost a fraction of a tick, carried in `subTicks` so
    /// the total stays exact and deterministic. Memory, I/O and every
    /// other device keep their real speeds, so games' timers do too.
    public var turboShift: UInt64 = 0
    var subTicks: UInt64 = 0

    @inline(__always) func processorCycles(_ n: UInt64) {
        if turboShift == 0 { ticks &+= n; return }
        subTicks &+= n
        ticks &+= subTicks >> turboShift
        subTicks &= (1 << turboShift) - 1
    }

    public func internalCycles(_ n: UInt64) {
        if cacheOn { processorCycles(n) } else { ticks &+= n &* sCycle }
    }

    /// A cacheable read that hits costs one processor cycle; a miss fetches
    /// the 16-byte line (one N and three S memory cycles) and fills it.
    func readWordCached(_ address: UInt32, sequential: Bool) -> UInt32 {
        let a = address & 0x03FF_FFFF
        guard let c = cache, !romOverlay, c.isCacheable(a) else {
            ticks &+= sCycle // synchronise to the memory clock
            return readWordMemory(address, sequential: sequential)
        }
        let start = ticks
        let v = readWordMemory(address, sequential: false)
        if abort { return v }
        cacheTiming(a, start: start, cache: c)
        return v
    }

    func readByteCached(_ address: UInt32) -> UInt32 {
        let a = address & 0x03FF_FFFF
        guard let c = cache, !romOverlay, c.isCacheable(a) else { ticks &+= sCycle; return readByteMemory(address) }
        let start = ticks
        let v = readByteMemory(address)
        if abort { return v }
        cacheTiming(a, start: start, cache: c)
        return v
    }

    @inline(__always) func cacheTiming(_ a: UInt32, start: UInt64, cache c: ARM3Cache) {
        if c.contains(a) {
            ticks = start
            processorCycles(1)
        } else {
            let first = ticks &- start
            c.fill(a)
            // Synchronising to the memory clock, then the line fill.
            ticks = start &+ sCycle &+ first &+ 3 &* (a >= 0x0380_0000 ? highROMTicks : sCycle)
        }
    }

    /// Writes go straight through to memory, after synchronising to its
    /// clock; one to a disruptive area (such as the CAM) flushes the cache.
    @inline(__always) func noteWrite(_ a: UInt32) {
        ticks &+= sCycle
        if let c = cache, (c.disruptive >> ((a & 0x03FF_FFFF) >> 21)) & 1 != 0 { c.flush() }
    }

    func checkWatch(_ physical: UInt32, _ value: UInt32) {
        if let w = writeWatch, w.contains(physical) { watchHit?(physical, value) }
    }

    func writeSlow(_ a: UInt32, _ value: UInt32, sequential: Bool, byte: Bool) {
        if a < 0x0300_0000 {
            ticks &+= sequential ? sCycle : nCycle
            if !privileged { abort = true; return }
            guard physicalFitted(a) else { return }
            let off = physicalOffset(a)
            if writeWatch != nil { checkWatch(UInt32(off), value) }
            if byte { ram[off] = UInt8(truncatingIfNeeded: value) } else { ramWordPointer(off).storeBytes(of: value, as: UInt32.self) }
            return
        }
        if !privileged { ticks &+= nCycle; abort = true; return }
        if a < 0x0340_0000 {
            io.write(a, value)
        } else if a < 0x0360_0000 {
            ticks &+= sCycle
            vidc.writeRegister(value)
        } else if a < 0x0380_0000 {
            ticks &+= sCycle
            writeControl(a)
        } else {
            ticks &+= sCycle
            writeCAM(a)
        }
    }

    // MARK: - MEMC registers

    func writeControl(_ a: UInt32) {
        let value = ((a >> 2) & 0x7FFF) << 4
        switch (a >> 17) & 7 {
        case 0: vinit = value
        case 1: vstart = value
        case 2: vend = value
        case 3: cinit = value
        case 4:
            soundRegisterLog.append(String(format: "t=%.4f Sstart=%05X", Double(ticks) / 24e6, value))
            sstart = value
            nextSoundBufferValid = true
            io.setSoundInterrupt(false)
        case 5:
            soundRegisterLog.append(String(format: "t=%.4f SendN=%05X", Double(ticks) / 24e6, value))
            sendNext = value
        case 6:
            soundRegisterLog.append(String(format: "t=%.4f Sptr reset", Double(ticks) / 24e6))
            soundBufferSwap()
        default:
            let newPageSize = (a >> 2) & 3
            lowROMSpeed = (a >> 4) & 3
            highROMSpeed = (a >> 6) & 3
            highROMTicks = [12, 9, 6, 6][Int(highROMSpeed)]
            refreshControl = (a >> 8) & 3
            videoDMAEnabled = a & (1 << 10) != 0
            soundDMAEnabled = a & (1 << 11) != 0
            osMode = a & (1 << 12) != 0
            updateLevels()
            if newPageSize != pageSizeCode { setPageSize(newPageSize) }
            vidc?.soundDMAEnableChanged()
        }
    }

    /// Called by the sound DMA when the current buffer is exhausted, and by
    /// software writing the Sptr reset register.
    func soundBufferSwap() {
        if nextSoundBufferValid {
            sendCurrent = sendNext
            nextSoundBufferValid = false
        }
        sptr = sstart
        io.setSoundInterrupt(true)
    }

    // MARK: Address translator

    func setPageSize(_ code: UInt32) {
        pageSizeCode = code
        rebuildPageTable()
    }

    /// The physical page a CAM write names, or nil when it's for a MEMC
    /// that isn't fitted.
    func decodePPN(_ a: UInt32) -> Int? {
        let memc = slaveMEMCs ? Int(((a >> 7) & 1) | (((a >> 12) & 1) << 1)) : 0
        guard memc < memcCount else { return nil }
        let page: UInt32
        switch pageSizeCode {
        case 0: page = a & 0x7F
        case 1: page = ((a >> 1) & 0x3F) | ((a & 1) << 6)
        case 2: page = ((a >> 2) & 0x1F) | ((a & 3) << 5)
        default: page = ((a >> 3) & 0xF) | ((a & 1) << 4) | (((a >> 2) & 1) << 5) | (((a >> 1) & 1) << 6)
        }
        return Int(page) | memc << 7
    }

    func decodeLPN(_ a: UInt32) -> UInt32 {
        ((((a >> 10) & 3) << 11) | ((a >> 12) & 0x7FF)) >> pageSizeCode
    }

    public var camLog = RingBuffer<String>(capacity: 256)
    /// A logical address whose page mapping changes are logged (debugging).
    public var watchedPage: UInt32?
    public var pageWatchLog: [String] = []

    func writeCAM(_ a: UInt32) {
        guard let ppn = decodePPN(a) else {
            camLog.append(String(format: "CAM %07X for an absent slave MEMC: ignored", a))
            return
        }
        camLog.append(String(format: "CAM %07X -> ppn %02X lpn %X ppl %d (pagesize %dK)", a, ppn, decodeLPN(a), (a >> 8) & 3, 4 << pageSizeCode))
        let old = camEntries[ppn]
        camEntries[ppn] = a
        camCounter &+= 1
        camSequence[ppn] = camCounter
        if old != .max { remap(logicalPage: decodeLPN(old)) }
        remap(logicalPage: decodeLPN(a))
    }

    /// Recompute the 4 KB page table slots for one logical page from the CAM.
    /// When several physical pages claim the same logical page the most
    /// recently written entry wins (real hardware produces an undefined
    /// page number; RISC OS POST relies on remapping taking effect).
    func remap(logicalPage lpn: UInt32) {
        let slots = 1 << Int(pageSizeCode)
        let pageBytes = 4096 << Int(pageSizeCode)
        var found = -1
        var ppl: UInt32 = 0
        var best: UInt64 = 0
        for ppn in camEntries.indices {
            let e = camEntries[ppn]
            if e != .max && decodeLPN(e) == lpn && camSequence[ppn] >= best { found = ppn; ppl = (e >> 8) & 3; best = camSequence[ppn] }
        }
        let first = Int(lpn) * slots
        if let w = watchedPage, Int(w >> 12) / slots == Int(lpn) {
            pageWatchLog.append(String(format: "%llu lpn %X -> %@", ticks, lpn, found < 0 ? "unmapped" : String(format: "ppn %02X ppl %d", found, ppl)))
        }
        for k in 0..<slots where first + k < 8192 {
            if found < 0 {
                pageTable[first + k] = 0
            } else {
                // Each MEMC's 128 pages lie in its own 4 MB.
                let phys = physicalOffset(UInt32((found >> 7) << 22 + (found & 127) * pageBytes + k * 4096))
                pageTable[first + k] = UInt32(phys) | (ppl << 24) | 0x0400_0000
            }
        }
    }

    func rebuildPageTable() {
        // A page size change re-interprets the CAM; rebuild from raw writes.
        let raw = camEntries.filter { $0 != .max }
        let seqs = zip(camEntries, camSequence).filter { $0.0 != .max }.map { $0.1 }
        camEntries = [UInt32](repeating: .max, count: camEntries.count)
        for i in 0..<8192 { pageTable[i] = 0 }
        for (a, q) in zip(raw, seqs) {
            guard let p = decodePPN(a) else { continue }
            camEntries[p] = a; camSequence[p] = q
        }
        var done = Set<UInt32>()
        for a in camEntries where a != .max {
            let l = decodeLPN(a)
            if done.insert(l).inserted { remap(logicalPage: l) }
        }
    }

    // MARK: - Debugger access (no timing, no side effects)

    /// Translate a logical address for the debugger; nil if unmapped.
    public func debugTranslate(_ address: UInt32) -> UInt32? {
        let a = address & 0x03FF_FFFF
        if a < 0x0200_0000 {
            let e = pageTable[Int((a >> 12) & 0x1FFF)]
            if e & 0x0400_0000 == 0 { return nil }
            return (e & 0x00FF_FFFF) | (a & 0xFFF)
        }
        return nil
    }

    public enum DebugSpace: String, Sendable { case logical, physical }

    public func debugRead(_ address: UInt32, space: DebugSpace) -> UInt8? {
        switch space {
        case .physical:
            return physicalFitted(address) ? ram[physicalOffset(address)] : nil
        case .logical:
            let a = address & 0x03FF_FFFF
            if romOverlay { return rom[Int(a) & romMask] }
            if a < 0x0200_0000 {
                guard let p = debugTranslate(a) else { return nil }
                return ram[Int(p) & ramMask]
            }
            if a < 0x0300_0000 { return physicalFitted(a) ? ram[physicalOffset(a)] : nil }
            if a >= 0x0380_0000 { return rom[Int(a) & romMask] }
            return nil
        }
    }

    public func debugWrite(_ address: UInt32, _ value: UInt8, space: DebugSpace) -> Bool {
        switch space {
        case .physical:
            guard physicalFitted(address) else { return false }
            ram[physicalOffset(address)] = value
            return true
        case .logical:
            let a = address & 0x03FF_FFFF
            if a < 0x0200_0000 {
                guard let p = debugTranslate(a) else { return false }
                ram[Int(p) & ramMask] = value
                return true
            }
            if a < 0x0300_0000 { ram[physicalOffset(a)] = value; return true }
            return false
        }
    }

    public func debugReadWord(_ address: UInt32, space: DebugSpace) -> UInt32? {
        var v: UInt32 = 0
        for i in 0..<4 {
            guard let b = debugRead(address &+ UInt32(i), space: space) else { return nil }
            v |= UInt32(b) << (8 * UInt32(i))
        }
        return v
    }

    // MARK: - DMA helpers (physical RAM, used by VIDC)

    /// DMA addresses pass through the same DRAM multiplexing as the CPU's.
    @inline(__always) func dmaWord(_ byteAddress: UInt32) -> UInt32 {
        ramWordPointer(physicalOffset(byteAddress)).load(as: UInt32.self)
    }

    /// Advance the sound pointer one 16-byte block, swapping buffers at the end.
    func advanceSoundPointer() {
        if sptr >= sendCurrent { soundBufferSwap() } else { sptr &+= 16 }
    }
}

// MARK: - Snapshot state

extension MEMC {
    func saveState(_ w: inout StateWriter) {
        w.u64(ticks); w.bool(abort); w.bool(privileged)
        w.u32(UInt32(ramSize)); w.raw(UnsafePointer(ram), count: ramSize)
        w.u32s(camEntries); w.u64s(camSequence); w.u64(camCounter)
        for i in 0..<8192 { w.u32(pageTable[i]) }
        w.u32(pageSizeCode); w.u32(lowROMSpeed); w.u32(highROMSpeed); w.u32(refreshControl)
        w.bool(videoDMAEnabled); w.bool(soundDMAEnabled); w.bool(osMode); w.u64(highROMTicks); w.bool(romOverlay)
        for v in [vinit, vstart, vend, cinit, sstart, sendNext, sendCurrent, sptr, vptr, cptr] { w.u32(v) }
        w.bool(nextSoundBufferValid)
        cache?.saveState(&w)
        // Only turbo machines have it, so other snapshots keep their layout.
        if turboShift > 0 { w.u64(subTicks) }
    }

    func loadState(_ r: inout StateReader) throws {
        ticks = try r.u64(); abort = try r.bool(); privileged = try r.bool()
        let size = Int(try r.u32())
        guard size == ramSize else { throw SnapshotError.corrupt("RAM size \(size) does not match \(ramSize)") }
        try r.raw(into: ram, count: ramSize)
        camEntries = try r.u32s(count: camEntries.count); camSequence = try r.u64s(count: camSequence.count); camCounter = try r.u64()
        for i in 0..<8192 { pageTable[i] = try r.u32() }
        pageSizeCode = try r.u32(); lowROMSpeed = try r.u32(); highROMSpeed = try r.u32(); refreshControl = try r.u32()
        videoDMAEnabled = try r.bool(); soundDMAEnabled = try r.bool(); osMode = try r.bool()
        highROMTicks = try r.u64(); romOverlay = try r.bool()
        vinit = try r.u32(); vstart = try r.u32(); vend = try r.u32(); cinit = try r.u32()
        sstart = try r.u32(); sendNext = try r.u32(); sendCurrent = try r.u32(); sptr = try r.u32()
        vptr = try r.u32(); cptr = try r.u32()
        nextSoundBufferValid = try r.bool()
        try cache?.loadState(&r)
        if turboShift > 0 { subTicks = try r.u64() }
        cacheControlChanged()
        updateLevels()
    }
}
