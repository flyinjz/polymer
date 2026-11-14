// Reading and writing binary data. Reads are bounds-checked and return 0
// past the end, so malformed files can't crash a parser; callers check
// `isValid` ranges where it matters.

public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public var offset: Int

    @inlinable public init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }

    @inlinable public var remaining: Int { max(0, bytes.count - offset) }
    @inlinable public var isAtEnd: Bool { offset >= bytes.count }

    @inlinable public mutating func u8() -> UInt8 { defer { offset += 1 }; return bytes.u8(at: offset) }
    @inlinable public mutating func u16() -> UInt16 { defer { offset += 2 }; return bytes.u16(at: offset) }
    @inlinable public mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    @inlinable public mutating func u32() -> UInt32 { defer { offset += 4 }; return bytes.u32(at: offset) }
    @inlinable public mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
    @inlinable public mutating func skip(_ n: Int) { offset += n }
}

extension Array where Element == UInt8 {
    /// Big-endian reads at absolute offsets; 0 when out of range.
    @inlinable public func u8(at i: Int) -> UInt8 {
        i >= 0 && i < count ? self[i] : 0
    }
    @inlinable public func u16(at i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= count else { return 0 }
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }
    @inlinable public func i16(at i: Int) -> Int16 { Int16(bitPattern: u16(at: i)) }
    @inlinable public func u24(at i: Int) -> UInt32 {
        guard i >= 0, i + 3 <= count else { return 0 }
        return UInt32(self[i]) << 16 | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2])
    }
    @inlinable public func u32(at i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    @inlinable public func i32(at i: Int) -> Int32 { Int32(bitPattern: u32(at: i)) }

    /// Little-endian reads.
    @inlinable public func u16le(at i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= count else { return 0 }
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    @inlinable public func u32le(at i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    /// Big-endian appends.
    @inlinable public mutating func append(u16 v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(truncatingIfNeeded: v))
    }
    @inlinable public mutating func append(u32 v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8)); append(UInt8(truncatingIfNeeded: v))
    }
}
