// Lock-free single-producer, single-consumer (SPSC) ring buffer.
// Zero heap allocations and zero locks on all read/write operations.
import Synchronization

/// Lock-free single-producer, single-consumer ring buffer with power-of-two capacity.
///
/// One thread may call the producer methods (`push`, `write`) concurrently with
/// another thread calling the consumer methods (`pop`, `read`). `reset()` must
/// only be called when neither producer nor consumer is active.
public final class SPSCRingBuffer<Element: Sendable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutableBufferPointer<Element>
    private let readIndex: Atomic<Int>
    private let writeIndex: Atomic<Int>

    /// Creates a ring buffer with capacity rounded up to the next power of two (at least 2).
    public init(minimumCapacity: Int) {
        let clamped = max(2, minimumCapacity)
        var cap = 1
        while cap < clamped {
            cap <<= 1
        }
        self.capacity = cap
        self.mask = cap - 1
        let base = UnsafeMutablePointer<Element>.allocate(capacity: cap)
        self.storage = UnsafeMutableBufferPointer(start: base, count: cap)
        self.readIndex = Atomic<Int>(0)
        self.writeIndex = Atomic<Int>(0)
    }

    deinit {
        if let base = storage.baseAddress {
            let r = readIndex.load(ordering: .relaxed)
            let w = writeIndex.load(ordering: .relaxed)
            let count = w &- r
            for i in 0..<count {
                base.advanced(by: (r &+ i) & mask).deinitialize(count: 1)
            }
            base.deallocate()
        }
    }

    /// Number of elements currently available for the consumer to read.
    public var availableToRead: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return w &- r
    }

    /// Number of free slots currently available for the producer to write.
    public var availableToWrite: Int {
        capacity - availableToRead
    }

    public var isEmpty: Bool {
        availableToRead == 0
    }

    public var isFull: Bool {
        availableToRead == capacity
    }

    /// Pushes a single element. Returns `false` if the buffer is full.
    /// Real-time safe: zero allocations, zero locks.
    @discardableResult
    public func push(_ element: Element) -> Bool {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        if (w &- r) >= capacity {
            return false
        }
        guard let base = storage.baseAddress else { return false }
        base.advanced(by: w & mask).initialize(to: element)
        writeIndex.store(w &+ 1, ordering: .releasing)
        return true
    }

    /// Pops a single element. Returns `nil` if the buffer is empty.
    /// Real-time safe: zero allocations, zero locks.
    public func pop() -> Element? {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        if w == r {
            return nil
        }
        guard let base = storage.baseAddress else { return nil }
        let element = base.advanced(by: r & mask).move()
        readIndex.store(r &+ 1, ordering: .releasing)
        return element
    }

    /// Writes as many elements from `source` as fit without blocking.
    /// Returns the number of elements written. Real-time safe: zero allocations, zero locks.
    @discardableResult
    public func write(from source: UnsafeBufferPointer<Element>) -> Int {
        guard !source.isEmpty, let srcBase = source.baseAddress, let dstBase = storage.baseAddress else {
            return 0
        }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w &- r)
        let toWrite = min(free, source.count)
        guard toWrite > 0 else { return 0 }

        let startSlot = w & mask
        let firstPart = min(toWrite, capacity - startSlot)
        dstBase.advanced(by: startSlot).initialize(from: srcBase, count: firstPart)
        let secondPart = toWrite - firstPart
        if secondPart > 0 {
            dstBase.initialize(from: srcBase.advanced(by: firstPart), count: secondPart)
        }

        writeIndex.store(w &+ toWrite, ordering: .releasing)
        return toWrite
    }

    /// Convenience overload writing from an array slice or array.
    @discardableResult
    public func write(_ source: [Element]) -> Int {
        source.withUnsafeBufferPointer { write(from: $0) }
    }

    /// Reads up to `destination.count` elements into an already-initialized buffer.
    /// Returns the number of elements read. Real-time safe: zero allocations, zero locks.
    @discardableResult
    public func read(into destination: UnsafeMutableBufferPointer<Element>) -> Int {
        guard !destination.isEmpty, let dstBase = destination.baseAddress, let srcBase = storage.baseAddress else {
            return 0
        }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let avail = w &- r
        let toRead = min(avail, destination.count)
        guard toRead > 0 else { return 0 }

        let startSlot = r & mask
        let firstPart = min(toRead, capacity - startSlot)
        dstBase.moveUpdate(from: srcBase.advanced(by: startSlot), count: firstPart)
        let secondPart = toRead - firstPart
        if secondPart > 0 {
            dstBase.advanced(by: firstPart).moveUpdate(from: srcBase, count: secondPart)
        }

        readIndex.store(r &+ toRead, ordering: .releasing)
        return toRead
    }

    /// Convenience overload reading into a pre-allocated array.
    @discardableResult
    public func read(into destination: inout [Element], maxCount: Int? = nil) -> Int {
        let limit = min(destination.count, maxCount ?? destination.count)
        guard limit > 0 else { return 0 }
        return destination.withUnsafeMutableBufferPointer { buf in
            let slice = UnsafeMutableBufferPointer(start: buf.baseAddress, count: limit)
            return read(into: slice)
        }
    }

    /// Clears all buffered elements. Call only when producer and consumer are idle.
    public func reset() {
        if let base = storage.baseAddress {
            let r = readIndex.load(ordering: .acquiring)
            let w = writeIndex.load(ordering: .acquiring)
            let count = w &- r
            for i in 0..<count {
                base.advanced(by: (r &+ i) & mask).deinitialize(count: 1)
            }
        }
        readIndex.store(0, ordering: .releasing)
        writeIndex.store(0, ordering: .releasing)
    }
}

/// 64-bit float audio sample ring buffer.
public typealias AudioRingBuffer = SPSCRingBuffer<Double>
