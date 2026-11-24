// OpenType Variable Fonts: `fvar` (variation axes and named instances),
// `avar` (piecewise-linear axis coordinate mapping), `gvar` (shared tuples,
// tuple variation headers, packed point numbers/deltas), tuple scalar
// evaluation, and IUP (Interpolation of Untouched Points).
import PolymerBase

/// One variation axis parsed from the OpenType `fvar` table.
public struct VariationAxis: Equatable, Hashable, Sendable {
    public let tag: String
    public let tagValue: UInt32
    public let minValue: Double
    public let defaultValue: Double
    public let maxValue: Double
    public let flags: UInt16
    public let axisNameID: UInt16

    /// True when the axis has the `HIDDEN_AXIS` (0x0001) flag set.
    public var isHidden: Bool { flags & 0x0001 != 0 }

    public init(
        tag: String,
        tagValue: UInt32 = 0,
        minValue: Double,
        defaultValue: Double,
        maxValue: Double,
        flags: UInt16 = 0,
        axisNameID: UInt16 = 0
    ) {
        self.tag = tag
        self.tagValue = tagValue != 0 ? tagValue : VariableFontTable.encodeTag(tag)
        self.minValue = minValue
        self.defaultValue = defaultValue
        self.maxValue = maxValue
        self.flags = flags
        self.axisNameID = axisNameID
    }
}

/// A named instance (e.g. Regular, Medium, Bold) from the `fvar` table.
public struct NamedInstance: Equatable, Hashable, Sendable {
    public let subfamilyNameID: UInt16
    public let flags: UInt16
    public let coordinates: [Double]
    public let postScriptNameID: UInt16?

    public init(
        subfamilyNameID: UInt16,
        flags: UInt16 = 0,
        coordinates: [Double],
        postScriptNameID: UInt16? = nil
    ) {
        self.subfamilyNameID = subfamilyNameID
        self.flags = flags
        self.coordinates = coordinates
        self.postScriptNameID = postScriptNameID
    }
}

/// User-space variation coordinates keyed by 4-character OpenType axis tag (e.g. `"wght": 700`).
public struct VariationCoordinates: Equatable, Hashable, Sendable {
    public var values: [String: Double]

    public init(_ values: [String: Double] = [:]) {
        self.values = values
    }

    public subscript(tag: String) -> Double? {
        get { values[tag] }
        set { values[tag] = newValue }
    }
}

/// One point's delta and whether it was explicitly touched by a `gvar` tuple.
public struct GlyphVariationDelta: Equatable, Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    public var touched: Bool

    public init(dx: Double = 0, dy: Double = 0, touched: Bool = false) {
        self.dx = dx
        self.dy = dy
        self.touched = touched
    }
}

/// Parsed `avar` segment map pair (`fromCoordinate -> toCoordinate`) in `[-1.0, 1.0]`.
public struct AxisValueMap: Equatable, Hashable, Sendable {
    public let from: Double
    public let to: Double

    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }
}

/// Parsed `gvar` header, shared tuples, and raw glyph variation data slice.
public struct GVARTable: Equatable, Sendable {
    public let majorVersion: UInt16
    public let minorVersion: UInt16
    public let axisCount: Int
    public let glyphCount: Int
    public let sharedTuples: [[Double]]
    let data: [UInt8]
    let glyphDataArrayOffset: Int
    let glyphOffsets: [Int]

    public init?(data: [UInt8], offset: Int = 0, length: Int? = nil) {
        let limit = min(data.count, length.map { offset + $0 } ?? data.count)
        guard offset >= 0, offset + 20 <= limit else { return nil }
        let major = data.u16(at: offset)
        let minor = data.u16(at: offset + 2)
        guard major == 1, minor == 0 else { return nil }

        let axisCount = Int(data.u16(at: offset + 4))
        let sharedTupleCount = Int(data.u16(at: offset + 6))
        let sharedTuplesRel = Int(data.u32(at: offset + 8))
        let glyphCount = Int(data.u16(at: offset + 12))
        let flags = data.u16(at: offset + 14)
        let glyphDataArrayRel = Int(data.u32(at: offset + 16))
        let longOffsets = (flags & 0x0001) != 0

        let offsetsBytes = (glyphCount + 1) * (longOffsets ? 4 : 2)
        guard offset + 20 + offsetsBytes <= limit else { return nil }

        var gOffsets: [Int] = []
        gOffsets.reserveCapacity(glyphCount + 1)
        for i in 0...glyphCount {
            if longOffsets {
                gOffsets.append(Int(data.u32(at: offset + 20 + 4 * i)))
            } else {
                gOffsets.append(Int(data.u16(at: offset + 20 + 2 * i)) * 2)
            }
        }

        var shared: [[Double]] = []
        let sharedBase = offset + sharedTuplesRel
        if sharedTupleCount > 0, axisCount > 0 {
            shared.reserveCapacity(sharedTupleCount)
            for t in 0..<sharedTupleCount {
                let rowStart = sharedBase + t * axisCount * 2
                guard rowStart + axisCount * 2 <= limit else { break }
                var coords: [Double] = []
                coords.reserveCapacity(axisCount)
                for a in 0..<axisCount {
                    coords.append(Double(data.i16(at: rowStart + 2 * a)) / 16384.0)
                }
                shared.append(coords)
            }
        }

        self.majorVersion = major
        self.minorVersion = minor
        self.axisCount = axisCount
        self.glyphCount = glyphCount
        self.sharedTuples = shared
        self.data = Array(data[offset..<limit])
        self.glyphDataArrayOffset = glyphDataArrayRel
        self.glyphOffsets = gOffsets
    }

    /// One decoded tuple variation record for a glyph.
    public struct DecodedTupleVariation: Equatable, Sendable {
        public let peak: [Double]
        public let start: [Double]?
        public let end: [Double]?
        /// Nil means all points are explicitly listed in `xDeltas`/`yDeltas`; otherwise sparse point indices.
        public let pointNumbers: [Int]?
        public let xDeltas: [Double]
        public let yDeltas: [Double]
    }

    /// Decodes all tuple variation records for `glyphID` from the `gvar` table.
    public func tupleVariations(for glyphID: GlyphID) -> [DecodedTupleVariation] {
        let g = Int(glyphID)
        guard g >= 0, g + 1 < glyphOffsets.count else { return [] }
        let relStart = glyphOffsets[g]
        let relEnd = glyphOffsets[g + 1]
        guard relEnd > relStart else { return [] }
        let base = glyphDataArrayOffset + relStart
        let end = glyphDataArrayOffset + relEnd
        guard base >= 0, base + 4 <= end, end <= data.count else { return [] }

        let tvCountRaw = data.u16(at: base)
        let hasSharedPoints = (tvCountRaw & 0x8000) != 0
        let count = Int(tvCountRaw & 0x0FFF)
        let dataOffset = Int(data.u16(at: base + 2))
        var headerPos = base + 4
        var serializedPos = base + dataOffset
        guard serializedPos <= end else { return [] }

        var sharedPoints: [Int]? = nil
        if hasSharedPoints {
            sharedPoints = GVARTable.decodePackedPointNumbers(data, pos: &serializedPos, limit: end)
        }

        var out: [DecodedTupleVariation] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard headerPos + 4 <= end else { break }
            let varDataSize = Int(data.u16(at: headerPos))
            let tupleIndex = data.u16(at: headerPos + 2)
            headerPos += 4

            let embeddedPeak = (tupleIndex & 0x8000) != 0
            let intermediateRegion = (tupleIndex & 0x4000) != 0
            let privatePointNumbers = (tupleIndex & 0x2000) != 0
            let sharedIndex = Int(tupleIndex & 0x0FFF)

            var peak: [Double] = []
            if embeddedPeak {
                guard headerPos + axisCount * 2 <= end else { break }
                peak.reserveCapacity(axisCount)
                for a in 0..<axisCount {
                    peak.append(Double(data.i16(at: headerPos + 2 * a)) / 16384.0)
                }
                headerPos += axisCount * 2
            } else if sharedIndex < sharedTuples.count {
                peak = sharedTuples[sharedIndex]
            } else {
                peak = [Double](repeating: 0, count: axisCount)
            }

            var startTuple: [Double]? = nil
            var endTuple: [Double]? = nil
            if intermediateRegion {
                guard headerPos + axisCount * 4 <= end else { break }
                var s: [Double] = []
                var e: [Double] = []
                s.reserveCapacity(axisCount)
                e.reserveCapacity(axisCount)
                for a in 0..<axisCount {
                    s.append(Double(data.i16(at: headerPos + 2 * a)) / 16384.0)
                }
                headerPos += axisCount * 2
                for a in 0..<axisCount {
                    e.append(Double(data.i16(at: headerPos + 2 * a)) / 16384.0)
                }
                headerPos += axisCount * 2
                startTuple = s
                endTuple = e
            }

            let tupleDataEnd = min(end, serializedPos + varDataSize)
            var p = serializedPos
            serializedPos = tupleDataEnd

            let points: [Int]?
            if privatePointNumbers {
                points = GVARTable.decodePackedPointNumbers(data, pos: &p, limit: tupleDataEnd)
            } else {
                points = sharedPoints
            }

            let xDeltas: [Double]
            let yDeltas: [Double]
            if let pts = points {
                xDeltas = GVARTable.decodePackedDeltas(data, count: pts.count, pos: &p, limit: tupleDataEnd)
                yDeltas = GVARTable.decodePackedDeltas(data, count: pts.count, pos: &p, limit: tupleDataEnd)
            } else {
                let all = GVARTable.decodeAllPackedDeltas(data, pos: &p, limit: tupleDataEnd)
                let half = all.count / 2
                xDeltas = Array(all[0..<half])
                yDeltas = Array(all[half..<(half * 2)])
            }

            out.append(DecodedTupleVariation(
                peak: peak,
                start: startTuple,
                end: endTuple,
                pointNumbers: points,
                xDeltas: xDeltas,
                yDeltas: yDeltas
            ))
        }
        return out
    }

    /// Decodes `gvar` packed point numbers. Returns `nil` when count is 0 ("all points").
    static func decodePackedPointNumbers(_ data: [UInt8], pos: inout Int, limit: Int) -> [Int]? {
        guard pos < limit else { return nil }
        let first = Int(data.u8(at: pos)); pos += 1
        if first == 0 { return nil }
        let totalCount: Int
        if first & 0x80 != 0 {
            guard pos < limit else { return [] }
            totalCount = ((first & 0x7F) << 8) | Int(data.u8(at: pos))
            pos += 1
        } else {
            totalCount = first
        }

        var points: [Int] = []
        points.reserveCapacity(totalCount)
        var lastPoint = 0
        while points.count < totalCount, pos < limit {
            let control = data.u8(at: pos); pos += 1
            let runCount = Int(control & 0x7F) + 1
            let words = (control & 0x80) != 0
            for _ in 0..<runCount {
                guard points.count < totalCount else { break }
                if words {
                    guard pos + 2 <= limit else { break }
                    lastPoint += Int(data.u16(at: pos)); pos += 2
                } else {
                    guard pos < limit else { break }
                    lastPoint += Int(data.u8(at: pos)); pos += 1
                }
                points.append(lastPoint)
            }
        }
        return points
    }

    static func decodePackedDeltas(_ data: [UInt8], count: Int, pos: inout Int, limit: Int) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(count)
        while out.count < count, pos < limit {
            let control = data.u8(at: pos); pos += 1
            let runCount = Int(control & 0x3F) + 1
            let zeros = (control & 0x80) != 0
            let words = (control & 0x40) != 0
            for _ in 0..<runCount {
                guard out.count < count else { break }
                if zeros {
                    out.append(0)
                } else if words {
                    guard pos + 2 <= limit else { out.append(0); break }
                    out.append(Double(data.i16(at: pos))); pos += 2
                } else {
                    guard pos < limit else { out.append(0); break }
                    out.append(Double(Int8(bitPattern: data.u8(at: pos)))); pos += 1
                }
            }
        }
        while out.count < count { out.append(0) }
        return out
    }

    static func decodeAllPackedDeltas(_ data: [UInt8], pos: inout Int, limit: Int) -> [Double] {
        var out: [Double] = []
        while pos < limit {
            let control = data.u8(at: pos); pos += 1
            let runCount = Int(control & 0x3F) + 1
            let zeros = (control & 0x80) != 0
            let words = (control & 0x40) != 0
            for _ in 0..<runCount {
                if zeros {
                    out.append(0)
                } else if words {
                    guard pos + 2 <= limit else { return out }
                    out.append(Double(data.i16(at: pos))); pos += 2
                } else {
                    guard pos < limit else { return out }
                    out.append(Double(Int8(bitPattern: data.u8(at: pos)))); pos += 1
                }
            }
        }
        return out
    }
}

/// Parsed OpenType Variable Font tables (`fvar`, optional `avar`, optional `gvar`)
/// plus coordinate normalization, tuple scalar evaluation, and IUP delta application.
public struct VariableFontTable: Equatable, Sendable {
    public let axes: [VariationAxis]
    public let instances: [NamedInstance]
    /// Segment maps from `avar` (indexed by axis order; empty if `avar` is absent).
    public let segmentMaps: [[AxisValueMap]]
    /// Parsed `gvar` table, if present.
    public let gvar: GVARTable?

    /// Parses `fvar` (required), plus optional `avar` and `gvar` tables from raw bytes.
    public init?(
        fvarData: [UInt8],
        fvarOffset: Int = 0,
        fvarLength: Int? = nil,
        avarData: [UInt8]? = nil,
        avarOffset: Int = 0,
        avarLength: Int? = nil,
        gvarData: [UInt8]? = nil,
        gvarOffset: Int = 0,
        gvarLength: Int? = nil
    ) {
        let fLimit = min(fvarData.count, fvarLength.map { fvarOffset + $0 } ?? fvarData.count)
        guard fvarOffset >= 0, fvarOffset + 16 <= fLimit else { return nil }
        let major = fvarData.u16(at: fvarOffset)
        let minor = fvarData.u16(at: fvarOffset + 2)
        guard major == 1, minor == 0 else { return nil }

        let axesArrayOffset = Int(fvarData.u16(at: fvarOffset + 4))
        let axisCount = Int(fvarData.u16(at: fvarOffset + 8))
        let axisSize = Int(fvarData.u16(at: fvarOffset + 10))
        let instanceCount = Int(fvarData.u16(at: fvarOffset + 12))
        let instanceSize = Int(fvarData.u16(at: fvarOffset + 14))
        guard axisSize >= 20 else { return nil }

        let axesBase = fvarOffset + axesArrayOffset
        guard axesBase + axisCount * axisSize <= fLimit else { return nil }

        var parsedAxes: [VariationAxis] = []
        parsedAxes.reserveCapacity(axisCount)
        for i in 0..<axisCount {
            let r = axesBase + i * axisSize
            let tagVal = fvarData.u32(at: r)
            let tagStr = VariableFontTable.decodeTag(tagVal)
            let minVal = Double(fvarData.i32(at: r + 4)) / 65536.0
            let defVal = Double(fvarData.i32(at: r + 8)) / 65536.0
            let maxVal = Double(fvarData.i32(at: r + 12)) / 65536.0
            let flags = fvarData.u16(at: r + 16)
            let nameID = fvarData.u16(at: r + 18)
            parsedAxes.append(VariationAxis(
                tag: tagStr,
                tagValue: tagVal,
                minValue: minVal,
                defaultValue: defVal,
                maxValue: maxVal,
                flags: flags,
                axisNameID: nameID
            ))
        }

        var parsedInstances: [NamedInstance] = []
        let instBase = axesBase + axisCount * axisSize
        let minInstSize = 4 + axisCount * 4
        if instanceCount > 0, instanceSize >= minInstSize, instBase + instanceCount * instanceSize <= fLimit {
            parsedInstances.reserveCapacity(instanceCount)
            let hasPostScriptID = instanceSize >= minInstSize + 2
            for i in 0..<instanceCount {
                let r = instBase + i * instanceSize
                let subID = fvarData.u16(at: r)
                let flags = fvarData.u16(at: r + 2)
                var coords: [Double] = []
                coords.reserveCapacity(axisCount)
                for a in 0..<axisCount {
                    coords.append(Double(fvarData.i32(at: r + 4 + 4 * a)) / 65536.0)
                }
                let psID: UInt16? = hasPostScriptID ? fvarData.u16(at: r + 4 + 4 * axisCount) : nil
                parsedInstances.append(NamedInstance(
                    subfamilyNameID: subID,
                    flags: flags,
                    coordinates: coords,
                    postScriptNameID: psID
                ))
            }
        }

        var parsedMaps: [[AxisValueMap]] = []
        if let avarData {
            parsedMaps = VariableFontTable.parseAvar(
                avarData, offset: avarOffset, length: avarLength, expectedAxisCount: axisCount
            )
        }

        let parsedGvar: GVARTable?
        if let gvarData {
            parsedGvar = GVARTable(data: gvarData, offset: gvarOffset, length: gvarLength)
        } else {
            parsedGvar = nil
        }

        self.axes = parsedAxes
        self.instances = parsedInstances
        self.segmentMaps = parsedMaps
        self.gvar = parsedGvar
    }

    static func parseAvar(
        _ data: [UInt8], offset: Int, length: Int?, expectedAxisCount: Int
    ) -> [[AxisValueMap]] {
        let limit = min(data.count, length.map { offset + $0 } ?? data.count)
        guard offset >= 0, offset + 8 <= limit else { return [] }
        let major = data.u16(at: offset)
        let minor = data.u16(at: offset + 2)
        guard major == 1, minor == 0 else { return [] }
        let axisCount = Int(data.u16(at: offset + 6))
        guard axisCount == expectedAxisCount else { return [] }

        var p = offset + 8
        var maps: [[AxisValueMap]] = []
        maps.reserveCapacity(axisCount)
        for _ in 0..<axisCount {
            guard p + 2 <= limit else { return [] }
            let pairCount = Int(data.u16(at: p)); p += 2
            guard p + pairCount * 4 <= limit else { return [] }
            var seg: [AxisValueMap] = []
            seg.reserveCapacity(pairCount)
            for _ in 0..<pairCount {
                let from = Double(data.i16(at: p)) / 16384.0
                let to = Double(data.i16(at: p + 2)) / 16384.0
                p += 4
                seg.append(AxisValueMap(from: from, to: to))
            }
            maps.append(seg)
        }
        return maps
    }

    /// Normalizes a single user-space coordinate into `[-1.0, 1.0]` per OpenType `fvar` + `avar`.
    public static func normalizeCoordinate(
        _ value: Double,
        axis: VariationAxis,
        segmentMap: [(Double, Double)]? = nil
    ) -> Double {
        let clamped = min(max(value, axis.minValue), axis.maxValue)
        var v: Double
        if clamped < axis.defaultValue {
            let span = axis.defaultValue - axis.minValue
            v = span > 0 ? (clamped - axis.defaultValue) / span : 0.0
        } else if clamped > axis.defaultValue {
            let span = axis.maxValue - axis.defaultValue
            v = span > 0 ? (clamped - axis.defaultValue) / span : 0.0
        } else {
            v = 0.0
        }

        if let map = segmentMap, map.count >= 2 {
            if v <= map[0].0 {
                v = map[0].1
            } else if v >= map[map.count - 1].0 {
                v = map[map.count - 1].1
            } else {
                for i in 0..<(map.count - 1) {
                    let (f0, t0) = map[i]
                    let (f1, t1) = map[i + 1]
                    if v >= f0 && v <= f1 {
                        if v == f0 {
                            v = t0
                        } else if v == f1 {
                            v = t1
                        } else if f1 > f0 {
                            let t = (v - f0) / (f1 - f0)
                            v = t0 + t * (t1 - t0)
                        } else {
                            v = t0
                        }
                        break
                    }
                }
            }
        }
        return min(max(v, -1.0), 1.0)
    }

    /// Normalizes `VariationCoordinates` across all axes in `self`, applying `avar` segment maps when present.
    public func normalize(_ coordinates: VariationCoordinates) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(axes.count)
        for (idx, axis) in axes.enumerated() {
            let userVal = coordinates[axis.tag] ?? axis.defaultValue
            let seg: [(Double, Double)]? = idx < segmentMaps.count && !segmentMaps[idx].isEmpty
                ? segmentMaps[idx].map { ($0.from, $0.to) }
                : nil
            out.append(VariableFontTable.normalizeCoordinate(userVal, axis: axis, segmentMap: seg))
        }
        return out
    }

    /// Evaluates the OpenType `gvar` tuple variation scalar for normalized `coordinates`.
    /// When `start` and `end` are omitted, the implicit region is `[min(0, peak), max(0, peak)]`.
    public static func tupleScalar(
        peak: [Double],
        start: [Double]? = nil,
        end: [Double]? = nil,
        coordinates: [Double]
    ) -> Double {
        var scalar = 1.0
        for i in 0..<peak.count {
            let p = peak[i]
            if p == 0.0 { continue }
            let c = i < coordinates.count ? coordinates[i] : 0.0
            let s: Double
            let e: Double
            if let start, let end, i < start.count, i < end.count {
                s = start[i]
                e = end[i]
                // Invalid OpenType intermediate region (must not cross 0 or misorder peak): ignore axis.
                if s > p || p > e || (s < 0 && e > 0) { continue }
            } else {
                s = min(0.0, p)
                e = max(0.0, p)
            }

            if c < s || c > e { return 0.0 }
            if c == p { continue }
            if c < p {
                let denom = p - s
                if denom == 0 { return 0.0 }
                scalar *= (c - s) / denom
            } else {
                let denom = e - p
                if denom == 0 { return 0.0 }
                scalar *= (e - c) / denom
            }
        }
        return scalar
    }

    /// Applies dense `(dx, dy)` deltas scaled by `scalar` to `points`.
    public static func applyDeltas(
        to points: [Point],
        deltas: [(dx: Double, dy: Double)],
        scalar: Double
    ) -> [Point] {
        guard scalar != 0 else { return points }
        var out = points
        let count = min(points.count, deltas.count)
        for i in 0..<count {
            out[i].x += deltas[i].dx * scalar
            out[i].y += deltas[i].dy * scalar
        }
        return out
    }

    /// Computes full per-point `(dx, dy)` deltas using TrueType/OpenType IUP
    /// (Interpolation of Untouched Points) for sparse `gvar` deltas.
    public static func interpolateUntouchedPoints(
        points: [Point],
        contourEndIndices: [Int],
        deltas: [GlyphVariationDelta]
    ) -> [(dx: Double, dy: Double)] {
        let n = points.count
        guard n > 0 else { return [] }
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        var touched = [Bool](repeating: false, count: n)
        let limit = min(n, deltas.count)
        for i in 0..<limit {
            dx[i] = deltas[i].dx
            dy[i] = deltas[i].dy
            touched[i] = deltas[i].touched
        }

        let origX = points.map(\.x)
        let origY = points.map(\.y)
        let ends = contourEndIndices.isEmpty ? [n - 1] : contourEndIndices

        var start = 0
        for end in ends {
            guard end >= start, end < n else { break }
            iupContour(start: start, end: end, orig: origX, touched: touched, delta: &dx)
            iupContour(start: start, end: end, orig: origY, touched: touched, delta: &dy)
            start = end + 1
        }

        var result: [(dx: Double, dy: Double)] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            result.append((dx: dx[i], dy: dy[i]))
        }
        return result
    }

    /// Applies sparse touched point deltas with IUP interpolation and scaling.
    public static func applySparseDeltas(
        to points: [Point],
        contourEndIndices: [Int],
        touchedDeltas: [Int: (dx: Double, dy: Double)],
        scalar: Double
    ) -> [Point] {
        guard scalar != 0, !points.isEmpty else { return points }
        var sparse = [GlyphVariationDelta](repeating: GlyphVariationDelta(), count: points.count)
        for (idx, d) in touchedDeltas where idx >= 0 && idx < points.count {
            sparse[idx] = GlyphVariationDelta(dx: d.dx, dy: d.dy, touched: true)
        }
        let full = interpolateUntouchedPoints(points: points, contourEndIndices: contourEndIndices, deltas: sparse)
        return applyDeltas(to: points, deltas: full, scalar: scalar)
    }

    /// Evaluates all `gvar` tuple variations for `glyphID` at `normalizedCoordinates`
    /// and returns the deformed outline points (applying IUP for sparse tuples).
    public func applyGlyphVariations(
        glyphID: GlyphID,
        to points: [Point],
        contourEndIndices: [Int],
        normalizedCoordinates: [Double]
    ) -> [Point] {
        guard let gvar, !points.isEmpty else { return points }
        let tuples = gvar.tupleVariations(for: glyphID)
        guard !tuples.isEmpty else { return points }

        var accumX = [Double](repeating: 0, count: points.count)
        var accumY = [Double](repeating: 0, count: points.count)

        for tv in tuples {
            let scalar = VariableFontTable.tupleScalar(
                peak: tv.peak, start: tv.start, end: tv.end, coordinates: normalizedCoordinates
            )
            if scalar == 0 { continue }

            let resolved: [(dx: Double, dy: Double)]
            if let ptNums = tv.pointNumbers {
                var sparse = [GlyphVariationDelta](repeating: GlyphVariationDelta(), count: points.count)
                let m = min(ptNums.count, min(tv.xDeltas.count, tv.yDeltas.count))
                for k in 0..<m {
                    let idx = ptNums[k]
                    if idx >= 0 && idx < points.count {
                        sparse[idx] = GlyphVariationDelta(dx: tv.xDeltas[k], dy: tv.yDeltas[k], touched: true)
                    }
                }
                resolved = VariableFontTable.interpolateUntouchedPoints(
                    points: points, contourEndIndices: contourEndIndices, deltas: sparse
                )
            } else {
                var dense: [(dx: Double, dy: Double)] = []
                dense.reserveCapacity(points.count)
                let m = min(points.count, min(tv.xDeltas.count, tv.yDeltas.count))
                for k in 0..<m {
                    dense.append((dx: tv.xDeltas[k], dy: tv.yDeltas[k]))
                }
                while dense.count < points.count { dense.append((0, 0)) }
                resolved = dense
            }

            for i in 0..<points.count {
                accumX[i] += resolved[i].dx * scalar
                accumY[i] += resolved[i].dy * scalar
            }
        }

        var out = points
        for i in 0..<points.count {
            out[i].x += accumX[i]
            out[i].y += accumY[i]
        }
        return out
    }

    private static func iupContour(
        start: Int, end: Int, orig: [Double], touched: [Bool], delta: inout [Double]
    ) {
        var touchedIndices: [Int] = []
        for i in start...end where touched[i] {
            touchedIndices.append(i)
        }
        guard !touchedIndices.isEmpty else { return }

        if touchedIndices.count == 1 {
            let shift = delta[touchedIndices[0]]
            for i in start...end where !touched[i] {
                delta[i] = shift
            }
            return
        }

        let count = end - start + 1
        let tCount = touchedIndices.count
        for k in 0..<tCount {
            let i1 = touchedIndices[k]
            let i2 = touchedIndices[(k + 1) % tCount]
            let c1 = orig[i1], c2 = orig[i2]
            let d1 = delta[i1], d2 = delta[i2]

            let minC: Double, minD: Double, maxC: Double, maxD: Double
            if c1 <= c2 {
                minC = c1; minD = d1; maxC = c2; maxD = d2
            } else {
                minC = c2; minD = d2; maxC = c1; maxD = d1
            }

            // Walk untouched indices strictly between i1 and i2 cyclically around the contour.
            var step = 1
            while step < count {
                let u = start + ((i1 - start + step) % count)
                if u == i2 { break }
                if !touched[u] {
                    let cu = orig[u]
                    if c1 == c2 {
                        delta[u] = (d1 == d2) ? d1 : 0.0
                    } else if cu <= minC {
                        delta[u] = minD
                    } else if cu >= maxC {
                        delta[u] = maxD
                    } else {
                        let t = (cu - minC) / (maxC - minC)
                        delta[u] = minD + t * (maxD - minD)
                    }
                }
                step += 1
            }
        }
    }

    static func decodeTag(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func encodeTag(_ tag: String) -> UInt32 {
        let bytes = Array(tag.utf8)
        let b0: UInt32 = bytes.count > 0 ? UInt32(bytes[0]) : 0x20
        let b1: UInt32 = bytes.count > 1 ? UInt32(bytes[1]) : 0x20
        let b2: UInt32 = bytes.count > 2 ? UInt32(bytes[2]) : 0x20
        let b3: UInt32 = bytes.count > 3 ? UInt32(bytes[3]) : 0x20
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

extension FontFace {
    /// Parsed OpenType variable font tables (`fvar`, optional `avar` and `gvar`), if present.
    public var variableFont: VariableFontTable? {
        guard let fvar = table("fvar") else { return nil }
        let avar = table("avar")
        let gvar = table("gvar")
        return VariableFontTable(
            fvarData: data,
            fvarOffset: fvar.offset,
            fvarLength: fvar.length,
            avarData: avar != nil ? data : nil,
            avarOffset: avar?.offset ?? 0,
            avarLength: avar?.length,
            gvarData: gvar != nil ? data : nil,
            gvarOffset: gvar?.offset ?? 0,
            gvarLength: gvar?.length
        )
    }
}
