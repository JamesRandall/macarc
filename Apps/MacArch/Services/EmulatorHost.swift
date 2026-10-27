import ArchimedesCore
import Foundation
import QuartzCore

/// Runs one machine on its own thread, or as a station of a network, on the
/// network's thread (see NetworkHost). Everything else talks to it with
/// `send`, whose closures run on that thread between slices of emulation,
/// and reads what it publishes (frame, lights) under a lock.
final class EmulatorHost: @unchecked Sendable {
    /// What a command closure gets: the machine and its history.
    final class Session {
        fileprivate(set) var machine: Machine
        let rewinder = Rewinder()
        unowned let host: EmulatorHost

        fileprivate init(machine: Machine, host: EmulatorHost) {
            self.machine = machine
            self.host = host
            rewinder.attach(machine)
        }

        /// Swap in a different machine (loaded state, rewind, power-on with
        /// new hardware). `keepHistory` is for rewinds within this timeline.
        func replace(with m: Machine, keepHistory: Bool = false) {
            host.attach(m)
            machine = m
            if !keepHistory { rewinder.reset() }
            rewinder.attach(m)
            host.resyncClock()
            host.publish(m.currentFrame)
            host.publishLights(m)
        }
    }

    struct Profile {
        var cmosPath: String
        /// False while running a loaded state: its CMOS is not the profile's.
        var persist = true
    }

    private let lock = NSLock()
    private var commands: [(Session) -> Void] = []
    private var thread: Thread?
    private var stopRequested = false
    private var pausedFlag = false
    private var speedLimitedFlag = true

    private var latestFrame = VideoFrame.blank
    private var latestLights = Machine.Lights()
    private var latestSeconds = 0.0
    private var latestDisc = DiscState()
    private var latestStop: String?
    private var latestStopCount = 0
    private var heldFlag = false

    /// Drive 0's image, as the window needs to know it.
    struct DiscState: Equatable {
        var modified = false
        /// Raw sector images can be written back; JFD cannot.
        var savable = false
        /// The image's file name.
        var name: String?
        /// What its kind of image is called: "adl" for L format, and so on.
        var fileExtension = "adf"
    }

    /// Starts and stops recordings for agents.
    var agentRecording: AgentRecordingHooks?

    /// Audio output and (while recording) the recorder; set before `start`.
    let audioSink: AudioSink
    /// Called on the emulation thread for every completed frame, with the
    /// guest time it completed at (for the recorder).
    var frameTap: ((VideoFrame, UInt64) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _frameTap }
        set { lock.lock(); _frameTap = newValue; lock.unlock() }
    }
    private var _frameTap: ((VideoFrame, UInt64) -> Void)?

    private var session: Session?
    private var profile: Profile
    private var savedCMOS: [UInt8] = []
    private var hostStart: CFTimeInterval = 0
    private var guestStart: UInt64 = 0
    private var lastCMOSSave: CFTimeInterval = 0

    /// A network's station: the network's thread runs it, in lockstep
    /// with the others, so it has no thread of its own.
    let isStation: Bool
    /// The network running it, if it's a station.
    weak var network: NetworkHost?
    /// The machine its network has on the line (a power cycle or a loaded
    /// state makes a new one). The network's thread's.
    var lineMachine: Machine?

    init(machine: Machine, profile: Profile, audioSink: AudioSink, isStation: Bool = false) {
        self.profile = profile
        self.audioSink = audioSink
        self.isStation = isStation
        let s = Session(machine: machine, host: self)
        session = s
        attach(machine)
    }

    // MARK: Main-thread API

    func start() {
        // A station's network runs it: a thread here would run it twice.
        guard thread == nil, !isStation else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "MacArch emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        if isStation { saveCMOSIfChanged(); return }
        lock.lock(); stopRequested = true; lock.unlock()
        while let t = thread, !t.isFinished { usleep(2000) }
        thread = nil
    }

    func send(_ command: @escaping (Session) -> Void) {
        lock.lock(); commands.append(command); lock.unlock()
        network?.needsAttention()
    }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pausedFlag }
        set { lock.lock(); pausedFlag = newValue; lock.unlock(); network?.needsAttention() }
    }

    var speedLimited: Bool {
        get { lock.lock(); defer { lock.unlock() }; return speedLimitedFlag }
        set { lock.lock(); speedLimitedFlag = newValue; lock.unlock(); send { $0.host.resyncClock() } }
    }

    var frame: VideoFrame { lock.lock(); defer { lock.unlock() }; return latestFrame }
    var lights: Machine.Lights { lock.lock(); defer { lock.unlock() }; return latestLights }
    var guestSeconds: Double { lock.lock(); defer { lock.unlock() }; return latestSeconds }
    var disc: DiscState { lock.lock(); defer { lock.unlock() }; return latestDisc }
    /// Why the debugger has stopped the machine (nil while it runs), and a
    /// count that changes with every new stop.
    var debugStop: String? { lock.lock(); defer { lock.unlock() }; return latestStop }
    var debugStopCount: Int { lock.lock(); defer { lock.unlock() }; return latestStopCount }

    /// An AI agent is holding the machine still between its tool calls.
    var heldForAgent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return heldFlag }
        set { lock.lock(); heldFlag = newValue; lock.unlock(); send { $0.host.resyncClock() } }
    }

    /// The session's machine, for the network's thread (the driving
    /// thread) only.
    var drivingMachine: Machine? { session?.machine }

    fileprivate func publishStop(_ m: Machine) {
        let d = m.debuggerIfCreated
        let reason = d?.stopReason.map { "\($0)" }
        let count = d?.stopCount ?? 0
        lock.lock(); latestStop = reason; latestStopCount = count; lock.unlock()
    }

    /// Like `send`, but waits for the command to run (briefly blocks the caller).
    func sendAndWait<T>(_ command: @escaping (Session) -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        send { result = command($0); done.signal() }
        done.wait()
        return result!
    }

    // MARK: Emulation thread

    fileprivate func attach(_ m: Machine) {
        m.vidc.audioSink = audioSink
        m.vidc.frameCompleted = { [weak self, unowned m] frame in
            m.ioc.pumpKeyboard()
            guard let self else { return }
            self.publish(frame)
            self.frameTap?(frame, m.ticks)
        }
    }

    fileprivate func publish(_ f: VideoFrame) {
        lock.lock(); latestFrame = f; lock.unlock()
    }

    fileprivate func publishLights(_ m: Machine) {
        let l = m.lights, s = m.seconds
        let image = m.fdc.drives[0].disc
        let d = DiscState(modified: image?.isModified ?? false, savable: image?.canSaveAsRawImage ?? false,
                          name: image.map { ($0.sourcePath as NSString?)?.lastPathComponent ?? "Disc" },
                          fileExtension: image.map { Self.fileExtension($0.geometry) } ?? "adf")
        lock.lock(); latestLights = l; latestSeconds = s; latestDisc = d; lock.unlock()
    }

    /// ADFS L, M and S images (256-byte sectors) are .adl, .adm and .ads.
    static func fileExtension(_ g: DiscGeometry) -> String {
        guard g.sectorSize == 256 else { return "adf" }
        return g.sides == 2 ? "adl" : g.tracks == 40 ? "ads" : "adm"
    }

    fileprivate func resyncClock() {
        hostStart = CACurrentMediaTime()
        guestStart = session?.machine.ticks ?? 0
    }

    /// After an agent tool: the machine may have run ahead, so catch the
    /// real-time clock up and publish what changed.
    func agentTouched(_ s: Session) {
        resyncClock()
        publish(s.machine.currentFrame)
        publishLights(s.machine)
    }

    /// Profile CMOS handling (emulation thread).
    func changeProfile(_ p: Profile) { profile = p }

    func setPersistCMOS(_ on: Bool, session: Session) {
        profile.persist = on
        savedCMOS = session.machine.cmos
    }

    func restoreProfileCMOS(into m: Machine) {
        if let d = FileManager.default.contents(atPath: profile.cmosPath) { m.loadCMOS([UInt8](d)) }
        profile.persist = true
        savedCMOS = m.cmos
    }

    func saveCMOSIfChanged() {
        guard profile.persist, let m = session?.machine, m.cmos != savedCMOS else { return }
        let path = profile.cmosPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if (try? m.saveCMOS(to: path)) != nil { savedCMOS = m.cmos }
    }

    // MARK: Driving (its own thread, or its network's)

    /// Runs the queued commands. Returns whether there were any.
    @discardableResult
    func runCommands() -> Bool {
        guard let s = session else { return false }
        lock.lock()
        let cmds = commands
        commands.removeAll()
        lock.unlock()
        // Commands (the UI's, and agents' tool calls) run even while
        // paused, held or stopped in the debugger.
        for c in cmds { c(s) }
        return !cmds.isEmpty
    }

    /// Whether the machine should run now: not paused (a station:
    /// suspended), held for an agent or stopped in the debugger. Publishes
    /// the debugger's state.
    func readyToRun() -> Bool {
        guard let m = session?.machine else { return false }
        publishStop(m)
        lock.lock()
        let ready = !pausedFlag && !heldFlag
        lock.unlock()
        return ready && !m.isStoppedByDebugger
    }

    /// Runs the machine for `ticks` (a network's quantum). Returns false
    /// if the debugger stopped it.
    func step(ticks: UInt64) -> Bool {
        guard let s = session else { return false }
        let stopped = s.machine.run(ticks: ticks) == .stopped
        ticksSincePublished &+= ticks
        // (Quanta are short: the lights and the rest needn't be published
        // every one.)
        if stopped || ticksSincePublished >= 800_000 {
            ticksSincePublished = 0
            publishLights(s.machine)
            publishStop(s.machine)
            let now = CACurrentMediaTime()
            if now - lastCMOSSave > 10 { saveCMOSIfChanged(); lastCMOSSave = now }
        }
        return !stopped
    }

    private var ticksSincePublished: UInt64 = 0

    /// A station joining its network: powered on, as a machine is.
    func powerOnForNetwork() {
        guard let s = session else { return }
        s.machine.powerOn()
        savedCMOS = s.machine.cmos
        lastCMOSSave = CACurrentMediaTime()
    }

    private func threadMain() {
        guard let s = session else { return }
        s.machine.powerOn()
        savedCMOS = s.machine.cmos
        resyncClock()
        lastCMOSSave = CACurrentMediaTime()
        var lastLights: CFTimeInterval = 0
        while true {
            lock.lock()
            let stop = stopRequested, paused = pausedFlag, limited = speedLimitedFlag, held = heldFlag
            lock.unlock()
            runCommands()
            if stop { break }
            let m = s.machine
            publishStop(m)
            let now = CACurrentMediaTime()
            if now - lastLights > 1.0 / 30 { publishLights(m); lastLights = now }
            if now - lastCMOSSave > 10 { saveCMOSIfChanged(); lastCMOSSave = now }
            if paused || held || m.isStoppedByDebugger { usleep(5_000); resyncClock(); continue }

            var target: UInt64
            if limited {
                target = guestStart &+ UInt64(max(0, now - hostStart) * Double(MasterClock.ticksPerSecond))
                // Never try to catch up more than 100 ms (e.g. after a stall).
                if target > m.ticks &+ 2_400_000 { target = m.ticks &+ 2_400_000; resyncClock() }
            } else {
                target = m.ticks &+ 480_000
            }
            if target > m.ticks, m.run(untilTick: target) == .stopped {
                publishStop(m)
                publishLights(m)
            }
            s.rewinder.captureIfDue(m)
            if limited { usleep(2000) }
        }
        saveCMOSIfChanged()
    }
}
