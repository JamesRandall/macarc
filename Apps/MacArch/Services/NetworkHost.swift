import ArchimedesCore
import Foundation
import QuartzCore

/// Runs a network's machines together on one thread, in lockstep: every
/// station runs to the same point in emulated time before any goes further,
/// so none can get ahead of another and miss what it sends. Each station is
/// an `EmulatorHost` without a thread of its own, so windows, debuggers and
/// agents use it just as they use a standalone machine's. (After MacBeeb's
/// NetworkHost.)
final class NetworkHost: @unchecked Sendable {
    /// The network's state as of its last quantum.
    struct Status: Equatable {
        /// Emulated network ticks (24 MHz) since the network started.
        var ticks: UInt64 = 0
        /// Emulated time against wall time over the last second or so (1 is
        /// real time).
        var speed: Double = 0
        /// The whole network is paused, by the user or a debugger stop.
        var paused = false
        /// The stations stopped by their debuggers.
        var stoppedStations: Set<UUID> = []
        /// What each Econet station has put on the line, by station number.
        var traffic: [UInt8: Traffic] = [:]
        /// Threads running the machines.
        var threads = 1
    }

    /// A station's transmissions so far.
    struct Traffic: Equatable {
        var bytes = 0
        /// Each frame ends with two check bytes.
        var checkBytes = 0
        var frames: Int { checkBytes / 2 }
        /// Byte-times spoiled by collisions.
        var collisions = 0
    }

    private enum Command {
        case add(UUID, EmulatorHost)
        case remove(UUID)
        case setClock(Int?)
        case attach(EconetLineDevice)
        case detach(EconetLineDevice)
    }

    private let lock = NSLock()
    private var commands: [Command] = []
    private var pausedFlag = false
    private var speedLimitedFlag = true
    private var pauseOnBreakpointFlag = true
    private var attention = true
    private var running = true
    private var latestStatus = Status()
    private var thread: Thread?

    /// The line. Used only on the network's thread.
    private let line: EconetLine
    private var traffic: [UInt8: Traffic] = [:]
    /// The frames on the line, as the traffic view and agents read them.
    private let trace = EconetTrace()
    private let traceLock = NSLock()

    init(clockRate: Int?) {
        line = EconetLine(clockRate: clockRate)
        line.observer = { [unowned self] event in observe(event) }
    }

    deinit { stop() }

    // MARK: Main-thread API

    func start() {
        guard thread == nil else { return }
        let t = Thread { [unowned self] in threadMain() }
        t.name = "MacArch network"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.withLock { running = false }
        while let t = thread, !t.isFinished { usleep(2000) }
        thread = nil
    }

    /// A station, run by this network from its next quantum. Don't `start`
    /// it: the network runs it.
    func addStation(id: UUID, host: EmulatorHost) {
        host.network = self
        lock.withLock { commands.append(.add(id, host)); attention = true }
    }

    /// Takes a station off the network: it stops running.
    func removeStation(id: UUID) {
        lock.withLock { commands.append(.remove(id)); attention = true }
    }

    /// The Econet's clock rate (nil takes it away).
    func setClock(_ rate: Int?) {
        lock.withLock { commands.append(.setClock(rate)); attention = true }
    }

    /// Puts a device (an Internet gateway) on the line, from the next quantum.
    func attach(device: EconetLineDevice) {
        lock.withLock { commands.append(.attach(device)); attention = true }
    }

    func detach(device: EconetLineDevice) {
        lock.withLock { commands.append(.detach(device)); attention = true }
    }

    /// Pauses every station together: no emulated time passes anywhere,
    /// so nothing on the network times out.
    func setPaused(_ paused: Bool) { lock.withLock { pausedFlag = paused; attention = true } }
    var isPaused: Bool { lock.withLock { pausedFlag } }

    /// Real time (true), or as fast as the Mac can go.
    func setSpeedLimited(_ limited: Bool) { lock.withLock { speedLimitedFlag = limited } }

    /// Whether a debugger stop on one station pauses the whole network (the
    /// default), or lets the others run on and perhaps time out.
    func setPauseOnBreakpoint(_ on: Bool) { lock.withLock { pauseOnBreakpointFlag = on; attention = true } }
    var pausesOnBreakpoint: Bool { lock.withLock { pauseOnBreakpointFlag } }

    /// A station has commands, or changed state: look at them all again.
    func needsAttention() { lock.withLock { attention = true } }

    var status: Status { lock.withLock { latestStatus } }

    // MARK: Trace

    /// Frames after `id` (all kept, if nil), newest last.
    func frames(after id: Int? = nil, limit: Int = .max) -> [EconetFrame] {
        traceLock.withLock { trace.frames(after: id, limit: limit) }
    }

    var isTracing: Bool { traceLock.withLock { trace.recording } }
    func setTracing(_ on: Bool) { traceLock.withLock { trace.recording = on } }
    func clearTrace() { traceLock.withLock { trace.clear() } }

    private func observe(_ event: EconetLineEvent) {
        traceLock.withLock { trace.observe(event) }
        switch event.symbol {
        case .byte: traffic[event.station, default: Traffic()].bytes += 1
        case .check: traffic[event.station, default: Traffic()].checkBytes += 1
        default: break
        }
        if event.collided { traffic[event.station, default: Traffic()].collisions += 1 }
    }

    // MARK: The network's thread

    /// The stations, in the order they run: by ID, so runs repeat.
    private var stations: [(id: UUID, host: EmulatorHost, slot: LockstepWorkers.Slot)] = []
    /// The stations that run this quantum.
    private var ready: [EmulatorHost] = []
    private var readySlots: [LockstepWorkers.Slot] = []
    private var publishedPaused = false
    private var publishedStopped: Set<UUID> = []
    /// Time was run on outside the wall clock's pacing (an agent's tool):
    /// pace from now, rather than wait for the wall clock to catch up.
    private var resyncClock = false

    /// Commands, stations' commands, and who's ready: only when something
    /// asked for attention (this would otherwise run every 16 µs).
    private func look() {
        let (cmds, paused, pauseOnBreak) = lock.withLock { () -> ([Command], Bool, Bool) in
            defer { commands.removeAll(); attention = false }
            return (commands, pausedFlag, pauseOnBreakpointFlag)
        }
        for command in cmds {
            switch command {
            case .add(let id, let host):
                stations.removeAll { $0.id == id }
                host.powerOnForNetwork()
                let slot = LockstepWorkers.Slot { [unowned self, unowned host] ticks in
                    // Stopped in its debugger: look again before the next quantum.
                    if !host.step(ticks: ticks) { needsAttention() }
                }
                stations.append((id, host, slot))
                stations.sort { $0.id.uuidString < $1.id.uuidString }
            case .remove(let id):
                if let station = stations.first(where: { $0.id == id }), let econet = station.host.lineMachine?.econet {
                    line.detach(econet)
                    station.host.lineMachine = nil
                    station.host.saveCMOSIfChanged()
                }
                stations.removeAll { $0.id == id }
            case .setClock(let rate):
                line.clockRate = rate
            case .attach(let device):
                line.attach(device: device)
            case .detach(let device):
                line.detach(device: device)
            }
        }
        ready.removeAll(keepingCapacity: true)
        readySlots.removeAll(keepingCapacity: true)
        var stopped: Set<UUID> = []
        for station in stations {
            station.host.runCommands()
            let machine = plugIn(station.host)
            if station.host.readyToRun() {
                ready.append(station.host)
                readySlots.append(station.slot)
            } else if machine?.isStoppedByDebugger == true {
                stopped.insert(station.id)
            }
        }
        let networkPaused = paused || (!stopped.isEmpty && pauseOnBreak)
        if networkPaused { ready.removeAll(); readySlots.removeAll() }
        groups = []
        let running = Set(ready.compactMap { $0.lineMachine?.econet }.map(ObjectIdentifier.init))
        line.setRunning { running.contains(ObjectIdentifier($0)) }
        if networkPaused != publishedPaused || stopped != publishedStopped {
            publishedPaused = networkPaused
            publishedStopped = stopped
            lock.withLock {
                latestStatus.paused = networkPaused
                latestStatus.stoppedStations = stopped
            }
        }
    }

    /// A power cycle or a loaded state makes a new machine: it takes the
    /// old one's place on the line. Returns the station's machine.
    @discardableResult
    private func plugIn(_ host: EmulatorHost) -> Machine? {
        let machine = host.drivingMachine
        if host.lineMachine !== machine {
            if let old = host.lineMachine?.econet { line.detach(old) }
            if let econet = machine?.econet { line.attach(econet) }
            host.lineMachine = machine
        }
        return machine
    }

    /// For a station's command (an agent's tool that runs its machine), on
    /// the network's thread: runs the network on by `ticks` there and
    /// then, every running station in step, and `host` even if it's held
    /// for the agent or stopped. A debugger stop on `host` ends it early.
    func runInline(ticks: UInt64, including host: EmulatorHost) {
        guard stations.contains(where: { $0.host === host }) else { return }
        plugIn(host)
        let hosts = stations.map(\.host).filter { $0 === host || ($0.lineMachine != nil && $0.readyToRun()) }
        let running = Set(hosts.compactMap { $0.lineMachine?.econet }.map(ObjectIdentifier.init))
        line.setRunning { running.contains(ObjectIdentifier($0)) }
        var left = ticks
        while left > 0 {
            let q = min(left, line.delay)
            line.beginQuantum()
            var stopped = false
            for h in hosts where !h.step(ticks: q) && h === host { stopped = true }
            line.endQuantum(ticks: q)
            left -= q
            if stopped { break }
        }
        resyncClock = true
        needsAttention()
    }

    /// One quantum: every ready station runs `line.delay` ticks, in turn.
    /// Returns whether anything ran.
    private func runQuantum() -> Bool {
        if lock.withLock({ attention }) { look() }
        guard !ready.isEmpty else { return false }
        line.beginQuantum()
        if workers.count == 0 {
            for slot in readySlots { slot.run(line.delay) }
        } else {
            if groups.count != workers.count + 1 { groups = LockstepWorkers.balance(readySlots, into: workers.count + 1) }
            workers.run(groups, ticks: line.delay)
        }
        line.endQuantum(ticks: line.delay)
        return true
    }

    // MARK: Threads

    /// The extra threads, when one isn't enough.
    private let workers = LockstepWorkers(name: "MacArch network")
    /// The ready stations, split between the threads (empty: to be split).
    private var groups: [[LockstepWorkers.Slot]] = []

    /// MACARCH_NETWORK_THREADS fixes the count (for measuring).
    static let fixedThreads = ProcessInfo.processInfo.environment["MACARCH_NETWORK_THREADS"].flatMap(Int.init)

    /// A thread on trial: the machine time a second before it, and the
    /// machines then.
    private var trial: (work: Double, machines: Int)?
    private var blockedAtMachines = 0
    private var growBlockedUntil = ContinuousClock.now

    private func setThreads(_ count: Int) {
        workers.resize(to: max(0, count - 1))
        groups = []
    }

    /// Once a second: another thread if the network's falling short of
    /// real time and never rests (kept only if it helps), one fewer if it
    /// rests a lot. (After MacBeeb's.)
    private func adjustThreads(speed: Double, restedFraction: Double, limited: Bool) {
        groups = [] // rebalanced on the costs just measured
        if let fixed = Self.fixedThreads {
            if workers.count != fixed - 1 { setThreads(fixed) }
            return
        }
        let threads = workers.count + 1
        let machines = stations.count
        // Machine time a second: what more threads can raise.
        let work = speed * Double(machines)
        if let trial {
            self.trial = nil
            if trial.machines == machines && work < trial.work * 1.05 {
                // The extra thread didn't help (by 5%): back to fewer, for a while.
                setThreads(threads - 1)
                growBlockedUntil = .now + .seconds(10)
                blockedAtMachines = machines
                return
            }
        }
        // Machines added or removed: a new network, as far as threads go.
        if machines != blockedAtMachines { growBlockedUntil = .now }
        let falling = (limited ? speed < 0.98 : true) && restedFraction < 0.02
        if falling && threads < LockstepWorkers.maxThreads && machines > threads && ContinuousClock.now >= growBlockedUntil {
            trial = (work, machines)
            setThreads(threads + 1)
        } else if threads > 1 && limited && (1 - restedFraction) * Double(threads) / Double(threads - 1) < 0.7 {
            setThreads(threads - 1)
        }
    }

    private func threadMain() {
        defer { workers.stop() }
        var rested = 0.0
        func rest(_ microseconds: UInt32) {
            let start = CACurrentMediaTime()
            usleep(microseconds)
            rested += CACurrentMediaTime() - start
        }
        var wallStart = CACurrentMediaTime()
        var wallStartTicks = line.time
        var sampleStart = wallStart
        var sampleTicks = line.time
        var trafficPublished = wallStart
        while lock.withLock({ running }) {
            let now = CACurrentMediaTime()
            if now - trafficPublished >= 0.1 {
                trafficPublished = now
                let traffic = traffic
                lock.withLock { latestStatus.traffic = traffic }
            }
            if now - sampleStart >= 1 {
                let speed = Double(line.time - sampleTicks) / Double(EconetTime.ticksPerSecond) / (now - sampleStart)
                let ticks = line.time
                if line.time > sampleTicks {
                    adjustThreads(speed: speed, restedFraction: rested / (now - sampleStart), limited: lock.withLock { speedLimitedFlag })
                }
                rested = 0
                let threads = workers.count + 1
                lock.withLock {
                    latestStatus.speed = speed
                    latestStatus.ticks = ticks
                    latestStatus.threads = threads
                }
                sampleStart = now
                sampleTicks = line.time
            }
            if resyncClock {
                resyncClock = false
                wallStart = now
                wallStartTicks = line.time
                // Nor is it counted in the speed.
                sampleStart = now
                sampleTicks = line.time
            }
            // Paced by the wall clock: about a millisecond's quanta at a time.
            if lock.withLock({ speedLimitedFlag }) {
                let due = UInt64(max(0, now - wallStart) * Double(EconetTime.ticksPerSecond))
                let done = line.time - wallStartTicks
                if done >= due {
                    if lock.withLock({ attention }) { look() }
                    rest(1000)
                    continue
                }
                // More than 0.1 s behind (the Mac was busy): carry on from
                // now rather than rushing to catch up.
                if due - done > EconetTime.ticksPerSecond / 10 {
                    wallStart = now
                    wallStartTicks = line.time
                }
            }
            var ran = false
            for _ in 0..<64 where runQuantum() { ran = true }
            if !ran {
                rest(5000)
                wallStart = CACurrentMediaTime()
                wallStartTicks = line.time
            }
        }
        for station in stations { station.host.saveCMOSIfChanged() }
    }
}
