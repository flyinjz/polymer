// Most-significant-bit-first reading over bytes, as FLAC and MPEG audio
// pack their fields. Reads past the end give zero bits; callers compare
// `position` with `bitCount` where running off the end matters.

struct BitReader {
    let base: UnsafePointer<UInt8>
    /// Bytes readable from `base`.
    let count: Int
    /// Bit position from `base`.
    var position: Int

    @inline(__always) init(_ base: UnsafePointer<UInt8>, count: Int, bitPosition: Int = 0) {
        self.base = base; self.count = count; self.position = bitPosition
    }

    var bitCount: Int { count * 8 }
    var bitsLeft: Int { count * 8 - position }
    var isByteAligned: Bool { position & 7 == 0 }
    var byteOffset: Int { position >> 3 }

    /// 64 bits starting at byte `i`, big-endian, zero past the end.
    @inline(__always) func word(_ i: Int) -> UInt64 {
        if i >= 0 && i + 8 <= count {
            return UnsafeRawPointer(base + i).loadUnaligned(as: UInt64.self).bigEndian
        }
        var w: UInt64 = 0
        for k in 0..<8 {
            let j = i + k
            w = w << 8 | (j >= 0 && j < count ? UInt64(base[j]) : 0)
        }
        return w
    }

    /// The next `n` bits (0...32) without moving.
    @inline(__always) func peek(_ n: Int) -> UInt32 {
        if n == 0 { return 0 }
        let w = word(position >> 3) << UInt64(position & 7)
        return UInt32(truncatingIfNeeded: w >> UInt64(64 - n))
    }

    /// The next `n` bits (0...32) as an unsigned number.
    @inline(__always) mutating func read(_ n: Int) -> UInt32 {
        let v = peek(n)
        position += n
        return v
    }

    @inline(__always) mutating func bit() -> Bool { read(1) != 0 }

    /// The next `n` bits (1...32) as a two's-complement number.
    @inline(__always) mutating func readSigned(_ n: Int) -> Int32 {
        let v = read(n)
        if n == 32 { return Int32(bitPattern: v) }
        let shift = UInt32(32 - n)
        return Int32(bitPattern: v << shift) >> Int32(shift)
    }

    /// Up to 64 bits, for long fields (FLAC's 36-bit total sample count).
    mutating func read64(_ n: Int) -> UInt64 {
        if n <= 32 { return UInt64(read(n)) }
        let hi = UInt64(read(n - 32))
        return hi << 32 | UInt64(read(32))
    }

    @inline(__always) mutating func skip(_ n: Int) { position += n }

    mutating func alignToByte() { position = (position + 7) & ~7 }

    /// Counts zero bits up to the next 1 and skips past it (unary codes).
    /// Stops after `limit` zeros (corrupt data) and returns `limit`.
    @inline(__always) mutating func unary(limit: Int = 1 << 20) -> Int {
        var n = 0
        while position < bitCount {
            let w = word(position >> 3) << UInt64(position & 7)
            let avail = 64 - (position & 7)
            let z = w.leadingZeroBitCount
            if z < avail {
                n += z
                position += z + 1
                return n
            }
            n += avail
            position += avail
            if n >= limit { return limit }
        }
        return min(n, limit)
    }
}
