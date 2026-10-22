/// Fixed-capacity ring buffer used for bounded traces and event logs.
public struct RingBuffer<Element> {
    public private(set) var storage: [Element] = []
    public let capacity: Int
    private var head = 0
    public private(set) var totalAppended: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ e: Element) {
        totalAppended &+= 1
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    public var count: Int { storage.count }

    /// Elements oldest-first.
    public var elements: [Element] {
        if storage.count < capacity { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// The most recent `n` elements, oldest-first.
    public func last(_ n: Int) -> [Element] {
        let all = elements
        return Array(all.suffix(n))
    }
}
