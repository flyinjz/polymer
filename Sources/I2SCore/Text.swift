// String helpers the library needs, in the standard library only.
// `naturalCompare` replaces Foundation's localizedStandardCompare: it ignores
// case, orders runs of digits by value ("Track 2" before "Track 10"), and
// gives the same answer on every OS.

extension String {
    /// Negative, zero or positive: this string before, equal to, or after `other` in natural order.
    public func naturalCompare(_ other: String) -> Int {
        let a = Array(self.unicodeScalars), b = Array(other.unicodeScalars)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if isDigit(a[i]) && isDigit(b[j]) {
                var si = i, sj = j
                while si < a.count && a[si] == "0" { si += 1 }
                while sj < b.count && b[sj] == "0" { sj += 1 }
                var ei = si, ej = sj
                while ei < a.count && isDigit(a[ei]) { ei += 1 }
                while ej < b.count && isDigit(b[ej]) { ej += 1 }
                if ei - si != ej - sj { return ei - si < ej - sj ? -1 : 1 }
                var k = 0
                while k < ei - si {
                    if a[si + k] != b[sj + k] { return a[si + k].value < b[sj + k].value ? -1 : 1 }
                    k += 1
                }
                i = ei; j = ej
            } else {
                let x = fold(a[i]), y = fold(b[j])
                if x != y { return x.value < y.value ? -1 : 1 }
                i += 1; j += 1
            }
        }
        if i < a.count { return 1 }
        if j < b.count { return -1 }
        return 0
    }

    @inlinable public func naturallyPrecedes(_ other: String) -> Bool { naturalCompare(other) < 0 }

    /// Lower-case for ASCII; other scalars unchanged (full folding comes with the text module's Unicode tables).
    public var asciiLowercased: String {
        var out = String.UnicodeScalarView()
        for s in unicodeScalars { out.append(fold(s)) }
        return String(out)
    }
}

private func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
private func fold(_ s: Unicode.Scalar) -> Unicode.Scalar {
    s.value >= 65 && s.value <= 90 ? Unicode.Scalar(s.value + 32)! : s
}

/// "3:07" or "1:02:03"; "0:00" for negative or non-finite input. Matches Meimei's formatting.
public func formatClock(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
}

/// "44.1 kHz" or "48 kHz".
public func formatSampleRate(_ hz: Double) -> String {
    let khz = hz / 1000
    if khz.rounded() == khz { return "\(Int(khz)) kHz" }
    let tenths = Int((khz * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) kHz"
}
