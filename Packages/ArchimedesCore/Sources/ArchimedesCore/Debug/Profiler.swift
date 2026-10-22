import Foundation

/// Counts where the time goes: master-clock ticks and executions for every
/// instruction address, time in interrupt handlers (IRQ and FIQ mode) and
/// frames. The address space is 64 MB, so the counters live in 32 KB pages
/// allocated as code is found in them. It is reached only through the
/// debugger's hooks, so it costs nothing when off.
public final class Profiler {
    final class Page {
        var ticks = [UInt64](repeating: 0, count: 8192)
        var executions = [UInt32](repeating: 0, count: 8192)
    }

    var pages: [UInt32: Page] = [:]
    public private(set) var totalTicks: UInt64 = 0
    public private(set) var interruptTicks: UInt64 = 0
    public internal(set) var frames = 0

    var lastKey: UInt32 = .max
    var lastPage: Page?

    @inline(__always)
    func count(_ pc: UInt32, ticks: UInt64, interrupt: Bool) {
        let key = pc >> 15
        let page: Page
        if key == lastKey, let p = lastPage { page = p } else {
            if let p = pages[key] { page = p } else { page = Page(); pages[key] = page }
            lastKey = key; lastPage = page
        }
        let i = Int((pc >> 2) & 8191)
        page.ticks[i] &+= ticks
        page.executions[i] &+= 1
        totalTicks &+= ticks
        if interrupt { interruptTicks &+= ticks }
    }

    public struct Entry: Sendable {
        public var address: UInt32
        public var ticks: UInt64
        public var executions: UInt32
    }

    public struct Routine: Sendable {
        public var name: String
        public var ticks: UInt64
    }

    public struct Report: Sendable {
        public var totalTicks: UInt64
        public var interruptTicks: UInt64
        public var frames: Int
        public var hottest: [Entry]
        public var routines: [Routine]
        /// Every counted instruction (for colouring the disassembly).
        public var ticksByAddress: [UInt32: UInt64]
        public var ticksPerFrame: Double { frames > 0 ? Double(totalTicks) / Double(frames) : 0 }
        public var interruptShare: Double { totalTicks > 0 ? Double(interruptTicks) / Double(totalTicks) : 0 }
    }

    /// The busiest `top` instructions, and routines grouped by the nearest
    /// symbol below (or by 4 KB page when there is none).
    public func report(top: Int, symbols: SymbolTable) -> Report {
        var all: [Entry] = []
        var byAddress: [UInt32: UInt64] = [:]
        for (key, page) in pages {
            for i in 0..<8192 where page.executions[i] != 0 {
                let a = key << 15 | UInt32(i) << 2
                all.append(Entry(address: a, ticks: page.ticks[i], executions: page.executions[i]))
                byAddress[a] = page.ticks[i]
            }
        }
        var routines: [String: UInt64] = [:]
        for e in all {
            let name = symbols.nearest(below: e.address, within: 4096)?.name ?? String(format: "&%X page", e.address & ~0xFFF)
            routines[name, default: 0] += e.ticks
        }
        all.sort { $0.ticks > $1.ticks }
        return Report(totalTicks: totalTicks, interruptTicks: interruptTicks, frames: frames,
                      hottest: Array(all.prefix(top)),
                      routines: routines.map { Routine(name: $0.key, ticks: $0.value) }.sorted { $0.ticks > $1.ticks },
                      ticksByAddress: byAddress)
    }
}
