// CFF (Compact Font Format) outlines: INDEX and DICT parsing and a Type 2
// charstring interpreter, CID-keyed fonts included.
import PolymerBase

struct CFF: Sendable {
    struct Index: Sendable {
        let count: Int
        let offSize: Int
        let offsets: Int     // position of the offset array
        let dataStart: Int   // position before the first byte of object data (offsets are 1-based)
        let end: Int

        init(_ d: [UInt8], at p: Int) {
            count = Int(d.u16(at: p))
            if count == 0 { offSize = 0; offsets = p + 2; dataStart = p + 2; end = p + 2; return }
            offSize = Int(d.u8(at: p + 2))
            offsets = p + 3
            dataStart = offsets + (count + 1) * offSize - 1
            end = dataStart + Index.read(d, offsets + count * offSize, offSize)
        }

        static func read(_ d: [UInt8], _ p: Int, _ size: Int) -> Int {
            var v = 0
            for k in 0..<size { v = v << 8 | Int(d.u8(at: p + k)) }
            return v
        }

        func range(_ d: [UInt8], _ i: Int) -> Range<Int>? {
            guard i >= 0, i < count else { return nil }
            let a = dataStart + Index.read(d, offsets + i * offSize, offSize)
            let b = dataStart + Index.read(d, offsets + (i + 1) * offSize, offSize)
            guard a <= b, b <= d.count else { return nil }
            return a..<b
        }
    }

    struct PrivateData: Sendable {
        let subrs: Index?
    }

    let charStrings: Index
    let globalSubrs: Index
    let privates: [PrivateData]   // one, or one per FD for CID fonts
    let fdSelect: Int             // absolute offset or -1

    init(data d: [UInt8], offset: Int, length: Int) throws(FontError) {
        let hdrSize = Int(d.u8(at: offset + 2))
        let names = Index(d, at: offset + hdrSize)
        let topDicts = Index(d, at: names.end)
        let strings = Index(d, at: topDicts.end)
        globalSubrs = Index(d, at: strings.end)
        guard let top = topDicts.range(d, 0) else { throw FontError("CFF has no Top DICT") }
        let dict = CFF.parseDict(d, top)
        guard let cs = dict[17]?.first else { throw FontError("CFF Top DICT has no CharStrings") }
        charStrings = Index(d, at: offset + Int(cs))
        if let fdArrayOff = dict[1236]?.first, let fdSel = dict[1237]?.first {
            let fdArray = Index(d, at: offset + Int(fdArrayOff))
            var ps: [PrivateData] = []
            for k in 0..<fdArray.count {
                guard let r = fdArray.range(d, k) else { ps.append(PrivateData(subrs: nil)); continue }
                ps.append(CFF.privateData(d, offset, CFF.parseDict(d, r)[18]))
            }
            privates = ps
            fdSelect = offset + Int(fdSel)
        } else {
            privates = [CFF.privateData(d, offset, dict[18])]
            fdSelect = -1
        }
    }

    static func privateData(_ d: [UInt8], _ base: Int, _ entry: [Double]?) -> PrivateData {
        guard let e = entry, e.count >= 2 else { return PrivateData(subrs: nil) }
        let size = Int(e[0]), off = base + Int(e[1])
        let pd = parseDict(d, off..<off + size)
        if let s = pd[19]?.first { return PrivateData(subrs: Index(d, at: off + Int(s))) }
        return PrivateData(subrs: nil)
    }

    /// DICT operators keyed by number (escaped operators as 1200 + n).
    static func parseDict(_ d: [UInt8], _ r: Range<Int>) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        var operands: [Double] = []
        var p = r.lowerBound
        while p < r.upperBound {
            let b = Int(d.u8(at: p))
            switch b {
            case 0...21:
                var op = b
                p += 1
                if b == 12 { op = 1200 + Int(d.u8(at: p)); p += 1 }
                out[op] = operands
                operands.removeAll()
            case 28: operands.append(Double(d.i16(at: p + 1))); p += 3
            case 29: operands.append(Double(d.i32(at: p + 1))); p += 5
            case 30:
                // Real number in nibbles.
                var s = ""
                p += 1
                loop: while p < r.upperBound {
                    let byte = d.u8(at: p); p += 1
                    for nib in [byte >> 4, byte & 15] {
                        switch nib {
                        case 0...9: s.append(Character(Unicode.Scalar(48 + nib)))
                        case 10: s.append(".")
                        case 11: s.append("E")
                        case 12: s.append("E-")
                        case 14: s.append("-")
                        case 15: break loop
                        default: break
                        }
                    }
                }
                operands.append(Double(s) ?? 0)
            case 32...246: operands.append(Double(b - 139)); p += 1
            case 247...250: operands.append(Double((b - 247) * 256 + Int(d.u8(at: p + 1)) + 108)); p += 2
            case 251...254: operands.append(Double(-(b - 251) * 256 - Int(d.u8(at: p + 1)) - 108)); p += 2
            default: p += 1
            }
        }
        return out
    }

    static func bias(_ count: Int) -> Int { count < 1240 ? 107 : (count < 33900 ? 1131 : 32768) }

    func fdIndex(_ d: [UInt8], _ g: Int) -> Int {
        guard fdSelect >= 0 else { return 0 }
        let format = d.u8(at: fdSelect)
        if format == 0 { return Int(d.u8(at: fdSelect + 1 + g)) }
        if format == 3 {
            let n = Int(d.u16(at: fdSelect + 1))
            for k in 0..<n {
                let r = fdSelect + 3 + 3 * k
                let first = Int(d.u16(at: r)), next = Int(d.u16(at: r + 3))
                if g >= first, g < next { return Int(d.u8(at: r + 2)) }
            }
        }
        return 0
    }

    func outline(_ d: [UInt8], _ g: Int, into path: inout Path) {
        guard let r = charStrings.range(d, g) else { return }
        let fd = fdIndex(d, g)
        var s = CharstringState(local: fd < privates.count ? privates[fd].subrs : nil, global: globalSubrs)
        s.run(d, r, depth: 0)
        if s.open { s.path.close() }
        path.elements.append(contentsOf: s.path.elements)
    }
}

struct CharstringState {
    let local: CFF.Index?
    let global: CFF.Index
    var stack: [Double] = []
    var x = 0.0, y = 0.0
    var stems = 0
    var widthParsed = false
    var open = false
    var done = false
    var path = Path()

    init(local: CFF.Index?, global: CFF.Index) {
        self.local = local; self.global = global
        stack.reserveCapacity(48)
    }

    mutating func moveTo(_ dx: Double, _ dy: Double) {
        if open { path.close() }
        x += dx; y += dy
        path.move(to: Point(x: x, y: y))
        open = true
    }
    mutating func lineTo(_ dx: Double, _ dy: Double) {
        x += dx; y += dy
        path.line(to: Point(x: x, y: y))
    }
    mutating func curveTo(_ dx1: Double, _ dy1: Double, _ dx2: Double, _ dy2: Double, _ dx3: Double, _ dy3: Double) {
        let c1 = Point(x: x + dx1, y: y + dy1)
        let c2 = Point(x: c1.x + dx2, y: c1.y + dy2)
        x = c2.x + dx3; y = c2.y + dy3
        path.cubic(to: Point(x: x, y: y), control1: c1, control2: c2)
    }

    /// The first stack-clearing operator may carry the advance width as an extra first operand.
    /// `expectEven`: the operator takes an even number of arguments (stems, rmoveto,
    /// endchar); otherwise one (hmoveto, vmoveto). An extra leading operand is the width.
    mutating func parseWidth(_ expectEven: Bool) {
        if !widthParsed {
            widthParsed = true
            let hasWidth = expectEven ? stack.count % 2 == 1 : stack.count % 2 == 0 && !stack.isEmpty
            if hasWidth { stack.removeFirst() }
        }
    }

    mutating func run(_ d: [UInt8], _ r: Range<Int>, depth: Int) {
        guard depth < 11 else { return }
        var p = r.lowerBound
        while p < r.upperBound, !done {
            let b = Int(d.u8(at: p))
            p += 1
            if b >= 32 || b == 28 {
                switch b {
                case 28: stack.append(Double(d.i16(at: p))); p += 2
                case 32...246: stack.append(Double(b - 139))
                case 247...250: stack.append(Double((b - 247) * 256 + Int(d.u8(at: p)) + 108)); p += 1
                case 251...254: stack.append(Double(-(b - 251) * 256 - Int(d.u8(at: p)) - 108)); p += 1
                default: stack.append(Double(d.i32(at: p)) / 65536); p += 4   // 255: 16.16 fixed
                }
                continue
            }
            switch b {
            case 1, 3, 18, 23:   // hstem, vstem, hstemhm, vstemhm
                parseWidth(true)
                stems += stack.count / 2
                stack.removeAll()
            case 19, 20:         // hintmask, cntrmask
                parseWidth(true)
                stems += stack.count / 2
                stack.removeAll()
                p += (stems + 7) / 8
            case 21:             // rmoveto
                parseWidth(true)
                if stack.count >= 2 { moveTo(stack[stack.count - 2], stack[stack.count - 1]) }
                stack.removeAll()
            case 22:             // hmoveto
                parseWidth(false)
                if let v = stack.last { moveTo(v, 0) }
                stack.removeAll()
            case 4:              // vmoveto
                parseWidth(false)
                if let v = stack.last { moveTo(0, v) }
                stack.removeAll()
            case 5:              // rlineto
                var i = 0
                while i + 1 < stack.count { lineTo(stack[i], stack[i + 1]); i += 2 }
                stack.removeAll()
            case 6, 7:           // hlineto, vlineto
                var horizontal = b == 6
                for v in stack {
                    if horizontal { lineTo(v, 0) } else { lineTo(0, v) }
                    horizontal.toggle()
                }
                stack.removeAll()
            case 8:              // rrcurveto
                var i = 0
                while i + 5 < stack.count {
                    curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]); i += 6
                }
                stack.removeAll()
            case 24:             // rcurveline
                var i = 0
                while i + 5 < stack.count - 2 {
                    curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]); i += 6
                }
                if i + 1 < stack.count { lineTo(stack[i], stack[i + 1]) }
                stack.removeAll()
            case 25:             // rlinecurve
                var i = 0
                while i + 1 < stack.count - 6 { lineTo(stack[i], stack[i + 1]); i += 2 }
                if i + 5 < stack.count {
                    curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5])
                }
                stack.removeAll()
            case 26:             // vvcurveto
                var i = 0
                var dx1 = 0.0
                if stack.count % 4 == 1 { dx1 = stack[0]; i = 1 }
                while i + 3 < stack.count {
                    curveTo(dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]); dx1 = 0; i += 4
                }
                stack.removeAll()
            case 27:             // hhcurveto
                var i = 0
                var dy1 = 0.0
                if stack.count % 4 == 1 { dy1 = stack[0]; i = 1 }
                while i + 3 < stack.count {
                    curveTo(stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0); dy1 = 0; i += 4
                }
                stack.removeAll()
            case 30, 31:         // vhcurveto, hvcurveto
                var horizontal = b == 31
                var i = 0
                while i + 3 < stack.count {
                    let last = i + 4 == stack.count - 1 ? stack[i + 4] : 0
                    if horizontal {
                        curveTo(stack[i], 0, stack[i + 1], stack[i + 2], last, stack[i + 3])
                    } else {
                        curveTo(0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], last)
                    }
                    horizontal.toggle()
                    i += 4
                }
                stack.removeAll()
            case 10, 29:         // callsubr, callgsubr
                guard let n = stack.popLast() else { done = true; break }
                let index: CFF.Index? = b == 10 ? local : global
                guard let idx = index, let sr = idx.range(d, Int(n) + CFF.bias(idx.count)) else { done = true; break }
                run(d, sr, depth: depth + 1)
            case 11:             // return
                return
            case 14:             // endchar
                parseWidth(true)
                if open { path.close(); open = false }
                done = true
            case 12:
                let e = Int(d.u8(at: p)); p += 1
                flex(e)
                stack.removeAll()
            default:
                stack.removeAll()
            }
        }
    }

    mutating func flex(_ e: Int) {
        let s = stack
        switch e {
        case 35 where s.count >= 12:   // flex
            curveTo(s[0], s[1], s[2], s[3], s[4], s[5]); curveTo(s[6], s[7], s[8], s[9], s[10], s[11])
        case 34 where s.count >= 7:    // hflex
            let y0 = y
            curveTo(s[0], 0, s[1], s[2], s[3], 0)
            curveTo(s[4], 0, s[5], y0 - (y), s[6], 0)
        case 36 where s.count >= 9:    // hflex1
            let y0 = y
            curveTo(s[0], s[1], s[2], s[3], s[4], 0)
            curveTo(s[5], 0, s[6], s[7], s[8], y0 - (y + s[7]))
        case 37 where s.count >= 11:   // flex1
            let x0 = x, y0 = y
            let dx = s[0] + s[2] + s[4] + s[6] + s[8], dy = s[1] + s[3] + s[5] + s[7] + s[9]
            curveTo(s[0], s[1], s[2], s[3], s[4], s[5])
            if abs(dx) > abs(dy) {
                curveTo(s[6], s[7], s[8], s[9], s[10], y0 - (y + s[7] + s[9]))
            } else {
                curveTo(s[6], s[7], s[8], s[9], x0 - (x + s[6] + s[8]), s[10])
            }
        default: break
        }
    }
}
