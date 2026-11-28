// Standard-library stand-ins for the Foundation string tools Meimei's Core
// used: CharacterSet trimming, literal replacement, String(format:) for
// fixed decimals, and UUID strings. All of it works on Unicode scalars and
// gives the same answer on every OS.

/// UUIDs as their 36-character uppercase string (what Foundation's
/// `UUID().uuidString` writes and what Meimei stores).
public enum UUIDString {
    /// A random version-4 UUID, uppercase.
    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        var a = g.next() as UInt64, b = g.next() as UInt64
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a); a >>= 8 }
        for i in 8..<16 { bytes[i] = UInt8(truncatingIfNeeded: b); b >>= 8 }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, byte) in bytes.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 { out.append("-") }
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(out)
    }

    /// `text` as a canonical uppercase UUID string, or nil if it is not
    /// 8-4-4-4-12 hex digits (either case), as `UUID(uuidString:)` accepts.
    public static func canonical(_ text: String) -> String? {
        var out = String.UnicodeScalarView()
        var n = 0
        for s in text.unicodeScalars {
            if n == 8 || n == 13 || n == 18 || n == 23 {
                guard s == "-" else { return nil }
                out.append(s)
            } else {
                let v = s.value
                switch v {
                case 48...57, 65...70: out.append(s)
                case 97...102: out.append(Unicode.Scalar(v - 32)!)
                default: return nil
                }
            }
            n += 1
            if n > 36 { return nil }
        }
        return n == 36 ? String(out) : nil
    }
}

/// Scalar-level text helpers (internal to I2SCore).
enum TextTools {
    // MARK: Character sets (Foundation's CharacterSet definitions)

    /// `.whitespaces`: Zs and tab.
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s.value == 9 || s.properties.generalCategory == .spaceSeparator
    }

    /// `.newlines`: U+000A–000D, U+0085, U+2028, U+2029.
    static func isNewline(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0A && v <= 0x0D) || v == 0x85 || v == 0x2028 || v == 0x2029
    }

    /// `.whitespacesAndNewlines`.
    static func isWhitespaceOrNewline(_ s: Unicode.Scalar) -> Bool { isWhitespace(s) || isNewline(s) }

    /// `.punctuationCharacters`: every P* category.
    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    /// `.alphanumerics`: L*, M* and N*.
    static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    // MARK: Editing

    /// `s` without leading and trailing scalars in the set.
    static func trimming(_ s: String, _ isTrimmed: (Unicode.Scalar) -> Bool) -> String {
        let u = Array(s.unicodeScalars)
        var lo = 0, hi = u.count
        while lo < hi && isTrimmed(u[lo]) { lo += 1 }
        while hi > lo && isTrimmed(u[hi - 1]) { hi -= 1 }
        if lo == 0 && hi == u.count { return s }
        return string(u[lo..<hi])
    }

    /// Whether `s` contains `target` (scalar for scalar).
    static func contains(_ s: String, _ target: String) -> Bool {
        let u = Array(s.unicodeScalars), t = Array(target.unicodeScalars)
        return find(t, in: u, from: 0) != nil
    }

    /// Every occurrence of `target` replaced by `replacement`, left to right, not overlapping.
    static func replacing(_ s: String, _ target: String, with replacement: String) -> String {
        let u = Array(s.unicodeScalars), t = Array(target.unicodeScalars)
        guard !t.isEmpty, var hit = find(t, in: u, from: 0) else { return s }
        var out = String.UnicodeScalarView()
        var i = 0
        while true {
            out.append(contentsOf: u[i..<hit])
            out.append(contentsOf: replacement.unicodeScalars)
            i = hit + t.count
            guard let next = find(t, in: u, from: i) else { break }
            hit = next
        }
        out.append(contentsOf: u[i...])
        return String(out)
    }

    /// `s` split at every scalar in the set (an empty piece between adjacent separators).
    static func components(_ s: String, separatedBy isSeparator: (Unicode.Scalar) -> Bool) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if isSeparator(c) { out.append(String(cur)); cur = String.UnicodeScalarView() }
            else { cur.append(c) }
        }
        out.append(String(cur))
        return out
    }

    static func string<C: Collection>(_ scalars: C) -> String where C.Element == Unicode.Scalar {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: scalars)
        return String(v)
    }

    private static func find(_ t: [Unicode.Scalar], in u: [Unicode.Scalar], from start: Int) -> Int? {
        guard !t.isEmpty, u.count >= t.count, start <= u.count - t.count else { return nil }
        var i = start
        while i <= u.count - t.count {
            var k = 0
            while k < t.count && u[i + k] == t[k] { k += 1 }
            if k == t.count { return i }
            i += 1
        }
        return nil
    }

    // MARK: Numbers

    /// `n` in decimal, zero-padded to `width` (printf `%0Nd` for n >= 0).
    static func zeroPadded(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// `n` in uppercase hex, zero-padded to `width` (printf `%0NX`).
    static func hexPadded(_ n: UInt32, _ width: Int) -> String {
        let s = String(n, radix: 16, uppercase: true)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// printf `%.Nf` for N in 0...3: the exact binary value rounded half to
    /// even, so "0.70" for 0.7 and "-0.0" for -0.04 at one decimal, as Darwin
    /// and glibc print.
    static func fixed(_ x: Double, _ decimals: Int) -> String {
        precondition(decimals >= 0 && decimals <= 3, "fixed(_:_:) supports 0 to 3 decimals")
        if x.isNaN { return "nan" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        let sign = x.sign == .minus ? "-" : ""
        let a = x.magnitude
        var scale: UInt64 = 1
        for _ in 0..<decimals { scale *= 10 }
        let q: UInt64
        if a == 0 {
            q = 0
        } else if a < 9_007_199_254_740_992 {
            // a = m * 2^lsb with lsb <= 0; q = round(m * 10^d / 2^-lsb).
            let normal = a.exponentBitPattern != 0
            let m = normal ? (a.significandBitPattern | (1 << 52)) : a.significandBitPattern
            let lsb = normal ? Int(a.exponentBitPattern) - 1075 : -1074
            let n = m * scale
            let shift = -lsb
            if shift == 0 {
                q = n
            } else if shift >= 64 {
                q = 0   // n < 2^63 <= half: rounds to zero
            } else {
                var r = n >> UInt64(shift)
                let rest = n & ((1 << UInt64(shift)) - 1)
                let half: UInt64 = 1 << UInt64(shift - 1)
                if rest > half || (rest == half && r & 1 == 1) { r += 1 }
                q = r
            }
        } else if a < 18_446_744_073_709_551_616 {
            // A whole number already; no fraction to round.
            let whole = UInt64(a)
            let frac = decimals == 0 ? "" : "." + String(repeating: "0", count: decimals)
            return sign + String(whole) + frac
        } else {
            return sign + "\(a)"
        }
        let whole = q / scale, frac = q % scale
        if decimals == 0 { return sign + String(whole) }
        return sign + String(whole) + "." + zeroPadded(Int(frac), decimals)
    }
}
