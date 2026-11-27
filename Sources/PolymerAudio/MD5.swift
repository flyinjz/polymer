// MD5 (RFC 1321), incremental, for checking FLAC's STREAMINFO signature of
// the decoded samples. Not used for anything security related.

struct MD5 {
    private var state: (UInt32, UInt32, UInt32, UInt32) = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476)
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var buffered = 0
    private var length: UInt64 = 0

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    /// floor(|sin(i + 1)| * 2^32), written out so it never depends on a libm.
    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    init() {}

    mutating func update(_ byte: UInt8) {
        buffer[buffered] = byte
        buffered += 1
        length &+= 1
        if buffered == 64 { block(); buffered = 0 }
    }

    mutating func update(_ bytes: [UInt8]) { for b in bytes { update(b) } }

    private mutating func block() {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(buffer[i * 4]) | UInt32(buffer[i * 4 + 1]) << 8 | UInt32(buffer[i * 4 + 2]) << 16 | UInt32(buffer[i * 4 + 3]) << 24
        }
        var (a, b, c, d) = state
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16: f = (b & c) | (~b & d); g = i
            case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) & 15
            case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) & 15
            default: f = c ^ (b | ~d); g = (7 * i) & 15
            }
            f = f &+ a &+ MD5.k[i] &+ m[g]
            a = d; d = c; c = b
            let r = MD5.s[i]
            b = b &+ (f << r | f >> (32 - r))
        }
        state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d)
    }

    /// The 16-byte digest. The value is consumed: make a new MD5 afterwards.
    mutating func finish() -> [UInt8] {
        let bits = length &* 8
        update(0x80)
        while buffered != 56 { update(0) }
        for i in 0..<8 { update(UInt8(truncatingIfNeeded: bits >> UInt64(8 * i))) }
        var out: [UInt8] = []
        for w in [state.0, state.1, state.2, state.3] {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * i))) }
        }
        return out
    }

    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var m = MD5()
        m.update(bytes)
        return m.finish()
    }
}
