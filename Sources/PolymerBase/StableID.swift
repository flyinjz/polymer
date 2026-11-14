// Deterministic 64-bit IDs. Swift's `Hasher` is seeded per process, so it
// can't name things across runs or OSes; StableID can.

public struct StableID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// FNV-1a over the UTF-8 bytes of `name`.
    @inlinable public init(_ name: String) {
        var h = StableHasher()
        h.combine(name)
        rawValue = h.value
    }

    /// The ID of `component` inside `self` (a path step).
    @inlinable public func appending(_ component: String) -> StableID {
        var h = StableHasher(seed: rawValue)
        h.combine(component)
        return StableID(rawValue: h.value)
    }

    @inlinable public static func < (a: StableID, b: StableID) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        let s = String(rawValue, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}

/// FNV-1a 64-bit hasher with a final avalanche, deterministic everywhere.
public struct StableHasher: Sendable {
    @usableFromInline var state: UInt64

    @inlinable public init(seed: UInt64 = 0xcbf29ce484222325) { state = seed }

    @inlinable public mutating func combine(byte: UInt8) {
        state = (state ^ UInt64(byte)) &* 0x100000001b3
    }
    @inlinable public mutating func combine(_ s: String) {
        for b in s.utf8 { combine(byte: b) }
        combine(byte: 0xFF)   // terminator so ("ab","c") != ("a","bc")
    }
    @inlinable public mutating func combine(_ v: UInt64) {
        var v = v
        for _ in 0..<8 { combine(byte: UInt8(truncatingIfNeeded: v)); v >>= 8 }
    }
    @inlinable public mutating func combine(_ bytes: some Sequence<UInt8>) {
        for b in bytes { combine(byte: b) }
    }

    /// Mixed value (splitmix64 finaliser).
    @inlinable public var value: UInt64 {
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
