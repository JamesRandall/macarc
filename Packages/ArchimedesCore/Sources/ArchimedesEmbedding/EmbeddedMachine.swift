import ArchimedesCore
import Foundation

/// An Archimedes for hosts that aren't the Mac app: a browser (through the
/// WebAssembly exports), a headless worker, or a native test comparing the
/// two. Everything goes in and comes out as bytes and integers: no file
/// paths, wall clocks or threads. The host decides when time passes, by
/// calling `run(ticks:)`.
///
/// It's a thin layer over `Machine`: the same emulation, snapshots,
/// launcher and video the app uses.
public final class EmbeddedMachine {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case badArgument(String)
        case rom(String)
        case configuration(String)
        case media(String)
        case snapshot(String)

        /// Stable codes for the C ABI (negated there).
        public var code: Int32 {
            switch self {
            case .badArgument: 2
            case .rom: 3
            case .configuration: 4
            case .media: 5
            case .snapshot: 6
            }
        }

        public var description: String {
            switch self {
            case .badArgument(let s): "bad argument: \(s)"
            case .rom(let s): "ROM: \(s)"
            case .configuration(let s): "configuration: \(s)"
            case .media(let s): "disc: \(s)"
            case .snapshot(let s): "snapshot: \(s)"
            }
        }
    }

    /// Largest file a host may hand over (ROMs are 2 MB, floppies 1.6 MB;
    /// snapshots of a 16 MB machine compress well below this).
    public static let maxInputBytes = 32 << 20
    /// Most ticks one `run` call may cover (10 guest seconds), so a host
    /// can't ask for unbounded work in one call.
    public static let maxRunTicks: UInt64 = 10 * UInt64(MasterClock.ticksPerSecond)

    public private(set) var machine: Machine
    public let rom: ROMImage
    /// Every floppy the host has given, by SHA-256, so a snapshot can find
    /// its discs again.
    private var floppies: [String: FloppyImage] = [:]
    private var launcher: ClassicLauncher?
    private var launcherDue: UInt64 = 0
    /// How often the launcher looks at the machine (the app's timer's 0.25 s).
    static let launcherInterval = UInt64(MasterClock.ticksPerSecond) / 4

    /// The latest frame as RGBA8 (row-major, top row first), and which
    /// frame it is.
    public private(set) var rgba: [UInt8] = []
    public private(set) var rgbaFrameNumber: UInt64 = .max
    public private(set) var frameWidth = 0
    public private(set) var frameHeight = 0
    public private(set) var frameScaleX = 1
    public private(set) var frameScaleY = 1

    private let audio = AudioCollector()

    /// - Parameters:
    ///   - model: a `MachineModel` raw value ("A3000", "A5000"...).
    ///   - ramKB: 0 for the model's usual memory.
    ///   - cmosReset: hold Delete at power-on, so RISC OS starts from its
    ///     default configuration (as the app does on a first boot and for a
    ///     Classic).
    ///   - rom: a RISC OS ROM image (one file, as the app takes).
    public init(model: String, ramKB: Int = 0, cmosReset: Bool = true, rom romBytes: [UInt8]) throws {
        guard romBytes.count <= Self.maxInputBytes else { throw Failure.badArgument("ROM is \(romBytes.count) bytes") }
        guard let m = MachineModel(rawValue: model) else {
            throw Failure.configuration("unknown model \(model) (one of " + MachineModel.allCases.map(\.rawValue).joined(separator: ", ") + ")")
        }
        do { rom = try ROMImage.build(parts: [romBytes], sources: ["host"]) } catch { throw Failure.rom("\(error)") }
        var c = MachineConfiguration(model: m)
        if ramKB != 0 { c.ramKB = ramKB }
        if cmosReset { c.powerOnKeys = [0x34] }
        do { machine = try Machine(configuration: c, rom: rom) } catch { throw Failure.configuration("\(error)") }
        machine.vidc.audioSink = audio
    }

    // MARK: Time

    public var ticks: UInt64 { machine.ticks }
    public var frameCount: UInt64 { machine.vidc.frameCount }
    public static var ticksPerSecond: Int { Int(MasterClock.ticksPerSecond) }

    /// Runs `n` ticks (24 MHz) of guest time, stepping a Classic's launcher
    /// at fixed guest times on the way (so the result doesn't depend on how
    /// the host divides time up).
    @discardableResult
    public func run(ticks n: UInt64) throws -> Machine.StopReason {
        guard n <= Self.maxRunTicks else { throw Failure.badArgument("run of \(n) ticks (at most \(Self.maxRunTicks))") }
        if !machine.poweredOn { machine.powerOn() }
        let target = machine.nominalTicks &+ n
        while launcher != nil && launcherDue <= target {
            let r = machine.run(untilTick: launcherDue)
            if r != .completed { return r }
            _ = launcher?.step(machine)
            launcherDue &+= Self.launcherInterval
        }
        return machine.run(untilTick: target)
    }

    public func powerOn() {
        machine.powerOn()
        if launcher != nil { launcherDue = machine.ticks &+ Self.launcherInterval }
    }

    public func reset() { machine.reset() }

    // MARK: Input

    /// A key (ArcKey code: 0x00-0x67, mouse buttons 0x70-0x72).
    public func key(_ code: Int, down: Bool) throws {
        guard (0...0x72).contains(code) else { throw Failure.badArgument("key code \(code)") }
        if down { machine.keyDown(UInt8(code)) } else { machine.keyUp(UInt8(code)) }
    }

    /// Mouse movement in mouse counts (up is positive y).
    public func mouseMove(dx: Int, dy: Int) {
        machine.mouseMove(dx: max(-1024, min(1024, dx)), dy: max(-1024, min(1024, dy)))
    }

    /// Lets go of every key and button (the host lost focus).
    public func releaseAllKeys() {
        for k in machine.keyboard.held { machine.keyUp(k) }
    }

    // MARK: Media

    /// Puts a floppy in (ADF, ADL, JFD, HFE...: the format's found from the contents).
    public func insertFloppy(_ bytes: [UInt8], drive: Int = 0, writeProtected: Bool = false) throws {
        guard (0..<4).contains(drive) else { throw Failure.badArgument("drive \(drive)") }
        let image = try Self.floppy(bytes, writeProtected: writeProtected)
        floppies[image.sha256] = image
        machine.insertFloppy(image, drive: drive)
    }

    public func ejectFloppy(drive: Int = 0) throws {
        guard (0..<4).contains(drive) else { throw Failure.badArgument("drive \(drive)") }
        machine.ejectFloppy(drive: drive)
    }

    /// A floppy's contents now, writes included.
    public func floppyContents(drive: Int = 0) -> [UInt8]? {
        guard (0..<4).contains(drive) else { return nil }
        return machine.fdc.drives[drive].disc?.mergedImage()
    }

    static func floppy(_ bytes: [UInt8], writeProtected: Bool) throws -> FloppyImage {
        guard bytes.count <= maxInputBytes else { throw Failure.badArgument("disc is \(bytes.count) bytes") }
        let det = MediaDetector.detect(bytes)
        do {
            switch det.format {
            case "JFD": return try JFDImage.load(bytes, sourcePath: nil, writeProtected: writeProtected)
            case "HFE": return try HFEImage.load(bytes, sourcePath: nil, writeProtected: writeProtected)
            default:
                guard let g = det.geometry else { throw Failure.media("\(det.format): \(det.notes)") }
                return FloppyImage(data: bytes, geometry: g, writeProtected: writeProtected)
            }
        } catch let f as Failure { throw f } catch { throw Failure.media("\(error)") }
    }

    // MARK: Classics

    /// Starts a Classic the way the app does: `gameJSON` is its entry from
    /// classics.json, `discs` its floppies in order (the first goes in
    /// drive 0). Call before the first `run`, on a machine made with
    /// `cmosReset`; the launcher then waits for the desktop, types the
    /// game's start and changes discs when the game asks.
    public func startClassic(gameJSON: [UInt8], discs: [[UInt8]]) throws {
        let game: ClassicGame
        do { game = try JSONDecoder().decode(ClassicGame.self, from: Data(gameJSON)) } catch {
            throw Failure.badArgument("game description: \(error)")
        }
        guard !discs.isEmpty else { throw Failure.badArgument("\(game.title) needs its discs") }
        let images = try discs.map { try Self.floppy($0, writeProtected: false) }
        for i in images { floppies[i.sha256] = i }
        machine.ejectFloppy()
        machine.insertFloppy(images[0])
        launcher = ClassicLauncher(game: game, floppies: images, machine: machine)
        launcherDue = machine.ticks &+ Self.launcherInterval
    }

    /// Whether the launcher has typed the game's start yet.
    public var classicStarted: Bool { launcher?.started ?? false }

    // MARK: Video

    /// Converts the latest completed frame to RGBA, if it's new. Returns
    /// whether `rgba` changed.
    @discardableResult
    public func updateFrame() -> Bool {
        let f = machine.vidc.lastFrame
        guard f.frameNumber != rgbaFrameNumber || f.width != frameWidth || f.height != frameHeight else { return false }
        let n = f.width * f.height
        if rgba.count != n * 4 { rgba = [UInt8](repeating: 0, count: n * 4) }
        f.pixels.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<min(n, src.count) {
                    let p = src[i]
                    dst[i * 4] = UInt8(truncatingIfNeeded: p >> 16)
                    dst[i * 4 + 1] = UInt8(truncatingIfNeeded: p >> 8)
                    dst[i * 4 + 2] = UInt8(truncatingIfNeeded: p)
                    dst[i * 4 + 3] = 0xFF
                }
            }
        }
        rgbaFrameNumber = f.frameNumber
        frameWidth = f.width; frameHeight = f.height
        frameScaleX = f.scaleX; frameScaleY = f.scaleY
        return true
    }

    /// The latest frame's FNV-1a checksum (the CLI's `frameChecksum`).
    public var frameChecksum: UInt64 { machine.vidc.lastFrame.checksum }

    // MARK: Audio

    /// Sets the rate audio is resampled to (0 turns audio off).
    public func setAudioRate(_ rate: Double) { audio.setRate(rate) }

    /// Interleaved stereo samples produced since the last call.
    public func takeAudio() -> [Float] { audio.take() }

    // MARK: Memory

    /// Guest memory, as the debugger sees it (no side effects); unmapped
    /// bytes read as 0.
    public func readMemory(_ address: UInt32, count: Int, logical: Bool) throws -> [UInt8] {
        guard count >= 0, count <= 1 << 20 else { throw Failure.badArgument("length \(count)") }
        let space: MEMC.DebugSpace = logical ? .logical : .physical
        return (0..<count).map { machine.memc.debugRead(address &+ UInt32($0), space: space) ?? 0 }
    }

    // MARK: Snapshots

    /// The machine's complete state (the app's .macarch-snapshot format).
    public func saveState() -> [UInt8] { machine.snapshot(createdBy: "MacArch embedding") }

    /// Replaces the machine with one restored from `bytes`. Its floppies
    /// must be ones this machine has been given.
    public func restoreState(_ bytes: [UInt8]) throws {
        guard bytes.count <= Self.maxInputBytes else { throw Failure.badArgument("snapshot is \(bytes.count) bytes") }
        let known = floppies
        let m: Machine
        do {
            m = try Machine.restore(snapshot: bytes, rom: rom, resolveDisc: { known[$0.sha256] })
        } catch { throw Failure.snapshot("\(error)") }
        machine.vidc.audioSink = nil
        machine = m
        machine.vidc.audioSink = audio
        launcher = nil
        rgbaFrameNumber = .max
    }

    // MARK: Status

    public var cpuPC: UInt32 { machine.cpu.currentInstructionAddress }
    public var romVersion: String { rom.versionString }
    /// Text RISC OS has printed lately (VDU output).
    public var recentText: String { machine.recentText }
}

/// Collects VIDC output resampled to the host's rate.
final class AudioCollector: AudioSink {
    private var resampler: BoxResampler?
    private var samples: [Float] = []
    /// About a second at 48 kHz: what's beyond it the host wasn't taking.
    static let limit = 2 * 48_000

    func setRate(_ rate: Double) {
        resampler = rate > 0 ? BoxResampler(outputRate: rate) : nil
        samples.removeAll()
    }

    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
        guard resampler != nil else { return }
        for _ in 0..<count {
            resampler!.push(left: left, right: right, inputRate: sampleRate) { l, r in
                samples.append(l); samples.append(r)
            }
        }
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
    }

    func take() -> [Float] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }
}
