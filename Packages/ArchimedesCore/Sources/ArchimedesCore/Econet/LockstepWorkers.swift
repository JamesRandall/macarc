#if canImport(Dispatch)
import Foundation
import Synchronization

/// Extra threads that run some of a network's machines through each
/// quantum alongside the network's own thread, then meet it before the line
/// delivers what they sent. Between those meetings the machines don't touch
/// each other, so which thread runs which machine can't change a result.
/// (After MacBeeb's.)
///
/// Quanta are 16 µs of emulated time, tens of thousands a second, so the
/// threads meet far too often to sleep in between: a thread waiting for the
/// next quantum spins, and only parks on a semaphore after it's been idle a
/// while (the network's ahead of real time, or paused).
public final class LockstepWorkers: @unchecked Sendable {
    /// One machine's part in a quantum, and what it costs to run.
    public final class Slot: @unchecked Sendable {
        let step: (UInt64) -> Void
        /// Nanoseconds a quantum, measured every 64th.
        public private(set) var cost = 0.0
        private var count = 0

        public init(step: @escaping (UInt64) -> Void) { self.step = step }

        /// Runs its quantum (measuring it now and then).
        @inline(__always)
        public func run(_ ticks: UInt64) {
            count &+= 1
            guard count & 63 == 0 else { step(ticks); return }
            let start = DispatchTime.now().uptimeNanoseconds
            step(ticks)
            let spent = Double(DispatchTime.now().uptimeNanoseconds - start)
            cost = cost == 0 ? spent : cost * 0.9 + spent * 0.1
        }
    }

    /// Each worker's machines for the coming quantum. Written by the
    /// network's thread before `generation` goes up; read by the worker after.
    private var groups: [[Slot]] = []
    private var ticks: UInt64 = 0
    private let generation = Atomic<Int>(0)
    private let finished = Atomic<Int>(0)
    private let stopping = Atomic<Bool>(false)
    private let leaving = Atomic<Int>(0)
    private var workers: [Worker] = []
    private let name: String

    private final class Worker: @unchecked Sendable {
        let parked = Atomic<Bool>(false)
        let wake = DispatchSemaphore(value: 0)
    }

    /// How long a worker spins for the next round before parking: long
    /// enough that a busy network's workers never park (a park and a wake
    /// cost more than a round's work), short enough that an idle one's
    /// soon stop using their cores.
    static let spinNanoseconds: UInt64 = 300_000

    public init(name: String = "Econet") { self.name = name }

    deinit { stop() }

    /// The extra threads (the caller's is one more).
    public var count: Int { workers.count }

    /// The most threads worth using: the performance cores, less one for
    /// the rest of the Mac.
    public static let maxThreads: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return max(1, Int(cores) - 1)
    }()

    /// Starts or stops workers until there are `count`.
    public func resize(to count: Int) {
        if count < workers.count { stop() }
        while workers.count < count {
            let worker = Worker()
            let index = workers.count
            workers.append(worker)
            groups.append([])
            stopping.store(false, ordering: .sequentiallyConsistent)
            // The round it starts from is now's: the thread may not get
            // going until after the next round's begun.
            let start = generation.load(ordering: .sequentiallyConsistent)
            let thread = Thread { [unowned self] in run(worker, index: index, from: start) }
            thread.name = "\(name) \(index + 2)"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    public func stop() {
        guard !workers.isEmpty else { return }
        stopping.store(true, ordering: .sequentiallyConsistent)
        generation.add(1, ordering: .sequentiallyConsistent)
        for worker in workers where worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
            worker.wake.signal()
        }
        // They leave (they're between rounds: run waits for each round).
        while leaving.load(ordering: .acquiring) < workers.count {}
        leaving.store(0, ordering: .sequentiallyConsistent)
        workers = []
        groups = []
    }

    /// Runs `ticks` of every machine: `groups[0]` on this thread, the rest
    /// on the workers, and returns when all are done.
    public func run(_ groups: [[Slot]], ticks: UInt64) {
        precondition(groups.count == workers.count + 1)
        for index in workers.indices { self.groups[index] = groups[index + 1] }
        self.ticks = ticks
        finished.store(0, ordering: .relaxed)
        // (Sequentially consistent, with the worker's side: a worker
        // parking as a round starts either sees the round or is seen
        // parked, never neither.)
        generation.add(1, ordering: .sequentiallyConsistent)
        for worker in workers where worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
            worker.wake.signal()
        }
        for slot in groups[0] { slot.run(ticks) }
        while finished.load(ordering: .acquiring) < workers.count {}
    }

    private func run(_ worker: Worker, index: Int, from start: Int) {
        var seen = start
        while true {
            // Wait for the next round: spin, then park.
            var spins = 0
            var spinStart: UInt64 = 0
            while generation.load(ordering: .acquiring) == seen {
                spins &+= 1
                // (The clock's read only every 1,024 turns.)
                if spins & 1023 != 0 { continue }
                let now = DispatchTime.now().uptimeNanoseconds
                if spinStart == 0 { spinStart = now }
                if now - spinStart < Self.spinNanoseconds { continue }
                worker.parked.store(true, ordering: .sequentiallyConsistent)
                if generation.load(ordering: .sequentiallyConsistent) != seen {
                    // A round started as we parked: if the network saw us
                    // parked, it signalled, and that's to be used up.
                    if !worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
                        worker.wake.wait()
                    }
                    break
                }
                worker.wake.wait()
                spins = 0
                spinStart = 0
            }
            seen = generation.load(ordering: .acquiring)
            if stopping.load(ordering: .acquiring) {
                leaving.add(1, ordering: .releasing)
                return
            }
            for slot in groups[index] { slot.run(ticks) }
            finished.add(1, ordering: .releasing)
        }
    }

    /// Splits `slots` into `count` groups of about equal cost, by their
    /// measured cost (the dearest first, each to the cheapest group).
    public static func balance(_ slots: [Slot], into count: Int) -> [[Slot]] {
        var groups = Array(repeating: [Slot](), count: count)
        var load = Array(repeating: 0.0, count: count)
        for slot in slots.sorted(by: { $0.cost > $1.cost }) {
            let index = load.indices.min { load[$0] < load[$1] }!
            groups[index].append(slot)
            load[index] += max(slot.cost, 1)
        }
        return groups
    }
}
#else
/// Hosts without threads (WebAssembly/WASI) run every machine on the
/// caller's thread; the results are the same however many threads.
public final class LockstepWorkers: @unchecked Sendable {
    public final class Slot: @unchecked Sendable {
        let step: (UInt64) -> Void
        public private(set) var cost = 0.0
        public init(step: @escaping (UInt64) -> Void) { self.step = step }
        @inline(__always) public func run(_ ticks: UInt64) { step(ticks) }
    }

    public init(name: String = "Econet") {}
    public var count: Int { 0 }
    public static let maxThreads = 1
    public func resize(to count: Int) {}
    public func stop() {}

    public func run(_ groups: [[Slot]], ticks: UInt64) {
        for group in groups { for slot in group { slot.run(ticks) } }
    }

    public static func balance(_ slots: [Slot], into count: Int) -> [[Slot]] { [slots] + Array(repeating: [], count: max(0, count - 1)) }
}
#endif
