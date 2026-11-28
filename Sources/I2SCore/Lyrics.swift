// Reading lyrics: synced `.lrc` or plain text, and which line is being sung.
// Ported from Meimei's Lyrics (no regular expressions: a small hand parser).

public struct LyricLine: Hashable, Sendable {
    public let id: Int
    public let time: Double
    public let text: String
}

public enum Lyrics {
    /// Synced lines when the text has LRC stamps, else the plain lines (trimmed, trailing blanks dropped).
    public static func read(_ raw: String) -> (lines: [LyricLine], synced: Bool) {
        let synced = parse(raw)
        if !synced.isEmpty { return (synced, true) }
        var texts = splitLines(raw).map { $0.trimmingSpaces }
        while texts.last?.isEmpty == true { texts.removeLast() }
        return (texts.enumerated().map { LyricLine(id: $0, time: 0, text: $1) }, false)
    }

    /// Index of the line being sung at `time` (offset already applied), or nil before the first.
    public static func currentIndex(in lines: [LyricLine], at time: Double) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    static func splitLines(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prevCR = false
        for ch in s.unicodeScalars {
            if ch == "\n" { if !prevCR { out.append(cur); cur = "" }; prevCR = false }
            else if ch == "\r" { out.append(cur); cur = ""; prevCR = true }
            else { cur.unicodeScalars.append(ch); prevCR = false }
        }
        out.append(cur)
        return out
    }

    /// `[mm:ss.xx]` at `i` (also `[mm:ss:xx]`, `[mm:ss]`): the time and the index after it.
    private static func stamp(_ u: [UInt8], _ i: Int, open: UInt8, close: UInt8) -> (Double, Int)? {
        guard i < u.count, u[i] == open else { return nil }
        var p = i + 1
        func digits(_ maxCount: Int) -> (Double, Int)? {
            var v = 0.0, n = 0
            while p < u.count, u[p] >= 48, u[p] <= 57, n < maxCount { v = v * 10 + Double(u[p] - 48); p += 1; n += 1 }
            return n == 0 ? nil : (v, n)
        }
        guard let (m, _) = digits(3), p < u.count, u[p] == 58 else { return nil }
        p += 1
        guard let (s, _) = digits(2) else { return nil }
        var frac = 0.0
        if p < u.count, u[p] == 46 || u[p] == 58 {
            p += 1
            guard let (f, n) = digits(3) else { return nil }
            var d = 1.0; for _ in 0..<n { d *= 10 }
            frac = f / d
        }
        guard p < u.count, u[p] == close else { return nil }
        return (m * 60 + s + frac, p + 1)
    }

    /// LRC: `[mm:ss.xx]text`, several stamps on one line. Word stamps (`<mm:ss.xx>`) are stripped.
    public static func parse(_ raw: String) -> [LyricLine] {
        var timed: [(Double, String)] = []
        for line in splitLines(raw) {
            let u = Array(line.utf8)
            var times: [Double] = [], kept: [UInt8] = []
            var i = 0
            while i < u.count {
                if let (t, next) = stamp(u, i, open: 91, close: 93) { times.append(t); i = next }
                else if let (_, next) = stamp(u, i, open: 60, close: 62) { i = next }
                else { kept.append(u[i]); i += 1 }
            }
            guard !times.isEmpty else { continue }
            let text = String(decoding: kept, as: UTF8.self).trimmingSpaces
            for t in times { timed.append((t, text)) }
        }
        // Stable by time so equal stamps keep file order.
        let order = timed.indices.sorted { timed[$0].0 != timed[$1].0 ? timed[$0].0 < timed[$1].0 : $0 < $1 }
        return order.enumerated().map { LyricLine(id: $0, time: timed[$1].0, text: timed[$1].1) }
    }
}
