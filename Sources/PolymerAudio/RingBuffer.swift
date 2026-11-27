// Single-producer single-consumer queues between the feeder thread (decoding)
// and the real-time thread (rendering). No locks, no allocation after init:
// each side owns one counter and reads the other's with acquire ordering.
// Counters are absolute frame numbers that only grow, so "frame 1234 of the
// stream" means the same thing on both sides.
import Synchronization

/// Interleaved Float frames.
final class SampleRing: @unchecked Sendable {
    let frames: Int
    let mask: Int
    let channels: Int
    let storage: UnsafeMutablePointer<Float>
    /// Frames ever written (the producer's counter).
    let writeCounter = Atomic<Int>(0)
    /// Frames ever consumed or skipped (the consumer's counter).
    let readCounter = Atomic<Int>(0)

    init(minimumFrames: Int, channels: Int) {
        var n = 1024
        while n < minimumFrames { n <<= 1 }
        frames = n; mask = n - 1; self.channels = channels
        storage = .allocate(capacity: n * channels)
        storage.initialize(repeating: 0, count: n * channels)
    }

    deinit { storage.deallocate() }

    // Producer side.

    var written: Int { writeCounter.load(ordering: .relaxed) }

    var freeFrames: Int { frames - (writeCounter.load(ordering: .relaxed) - readCounter.load(ordering: .acquiring)) }

    /// Appends `n` frames; the caller has checked `freeFrames`.
    func write(_ src: UnsafePointer<Float>, frames n: Int) {
        let w = writeCounter.load(ordering: .relaxed)
        let start = w & mask
        let first = min(n, frames - start)
        (storage + start * channels).update(from: src, count: first * channels)
        if n > first { storage.update(from: src + first * channels, count: (n - first) * channels) }
        writeCounter.store(w + n, ordering: .releasing)
    }

    // Consumer side.

    /// Frames ready to read at `read` (the consumer's own position).
    func available(from read: Int) -> Int { writeCounter.load(ordering: .acquiring) - read }

    @inline(__always) func pointer(at frame: Int) -> UnsafeMutablePointer<Float> { storage + (frame & mask) * channels }

    func release(to read: Int) { readCounter.store(read, ordering: .releasing) }
}

/// Where a track (or the end of everything) starts in the sample stream.
struct StreamMarker {
    /// The ring frame this applies from.
    var frame: Int
    /// The caller's token for the track; -1 marks the end of the queue.
    var token: Int
    /// Track time at `frame`, in seconds.
    var seconds: Double
}

final class MarkerQueue: @unchecked Sendable {
    static let capacity = 64
    let storage: UnsafeMutablePointer<StreamMarker>
    let head = Atomic<Int>(0)   // consumer
    let tail = Atomic<Int>(0)   // producer

    init() {
        storage = .allocate(capacity: MarkerQueue.capacity)
        storage.initialize(repeating: StreamMarker(frame: 0, token: -1, seconds: 0), count: MarkerQueue.capacity)
    }

    deinit { storage.deallocate() }

    /// Producer. False when full (the consumer has fallen 64 tracks behind).
    func push(_ m: StreamMarker) -> Bool {
        let t = tail.load(ordering: .relaxed)
        if t - head.load(ordering: .acquiring) >= MarkerQueue.capacity { return false }
        storage[t & (MarkerQueue.capacity - 1)] = m
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    var isFull: Bool { tail.load(ordering: .relaxed) - head.load(ordering: .acquiring) >= MarkerQueue.capacity }

    /// Consumer.
    func peek() -> StreamMarker? {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return nil }
        return storage[h & (MarkerQueue.capacity - 1)]
    }

    func pop() {
        let h = head.load(ordering: .relaxed)
        head.store(h + 1, ordering: .releasing)
    }
}
