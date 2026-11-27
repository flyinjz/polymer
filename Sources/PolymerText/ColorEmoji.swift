// Pure-Swift OpenType CPAL (Color Palette) and COLR v0 (Layered Color Glyphs) parser.
// Standard library + PolymerBase only — bounds-checked throughout.
import PolymerBase

/// Parsed OpenType `CPAL` (Color Palette) table (versions 0 and 1).
public struct CPALTable: Equatable, Sendable {
    /// Special palette entry index indicating the current foreground text color.
    public static let foregroundEntryIndex: UInt16 = 0xFFFF

    public let version: UInt16
    public let numPaletteEntries: Int
    public let numPalettes: Int
    public let numColorRecords: Int
    public let colorRecordsArrayOffset: Int
    public let colorRecordIndices: [UInt16]
    public let colorRecords: [Color]

    /// Parses a binary OpenType `CPAL` table starting at `offset`.
    public init?(data: [UInt8], offset: Int = 0, length: Int? = nil) {
        let limit = min(data.count, length.map { offset + $0 } ?? data.count)
        guard offset >= 0, offset + 12 <= limit else { return nil }

        let version = data.u16(at: offset)
        guard version == 0 || version == 1 else { return nil }

        let numPaletteEntries = Int(data.u16(at: offset + 2))
        let numPalettes = Int(data.u16(at: offset + 4))
        let numColorRecords = Int(data.u16(at: offset + 6))
        let colorRecordsOffset = Int(data.u32(at: offset + 8))

        let indicesEnd = offset + 12 + numPalettes * 2
        guard indicesEnd <= limit else { return nil }

        var indices: [UInt16] = []
        indices.reserveCapacity(numPalettes)
        for i in 0..<numPalettes {
            indices.append(data.u16(at: offset + 12 + i * 2))
        }

        let recordsStart = offset + colorRecordsOffset
        guard recordsStart >= offset, recordsStart + numColorRecords * 4 <= limit else { return nil }

        var records: [Color] = []
        records.reserveCapacity(numColorRecords)
        for i in 0..<numColorRecords {
            let p = recordsStart + i * 4
            let b = Double(data[p]) / 255.0
            let g = Double(data[p + 1]) / 255.0
            let r = Double(data[p + 2]) / 255.0
            let a = Double(data[p + 3]) / 255.0
            records.append(Color(red: r, green: g, blue: b, opacity: a))
        }

        self.version = version
        self.numPaletteEntries = numPaletteEntries
        self.numPalettes = numPalettes
        self.numColorRecords = numColorRecords
        self.colorRecordsArrayOffset = colorRecordsOffset
        self.colorRecordIndices = indices
        self.colorRecords = records
    }

    /// Returns the color for `(paletteIndex, entryIndex)`, or `nil` for out-of-range indices
    /// or the special `0xFFFF` foreground text color marker.
    public func color(paletteIndex: Int, entryIndex: Int) -> Color? {
        guard entryIndex != Int(Self.foregroundEntryIndex) else { return nil }
        guard paletteIndex >= 0, paletteIndex < numPalettes else { return nil }
        guard entryIndex >= 0, entryIndex < numPaletteEntries else { return nil }
        let recordIndex = Int(colorRecordIndices[paletteIndex]) + entryIndex
        guard recordIndex >= 0, recordIndex < colorRecords.count else { return nil }
        return colorRecords[recordIndex]
    }

    /// Resolves a CPAL palette entry index, substituting `foreground` when `entryIndex == 0xFFFF`
    /// or when the requested palette/entry is unavailable.
    public func resolveColor(paletteIndex: Int, entryIndex: UInt16, foreground: Color) -> Color {
        if entryIndex == Self.foregroundEntryIndex {
            return foreground
        }
        return color(paletteIndex: paletteIndex, entryIndex: Int(entryIndex)) ?? foreground
    }
}

/// One outline layer of a COLR v0 color glyph, drawn in painter's order.
public struct ColorGlyphLayer: Equatable, Hashable, Sendable {
    public var glyphID: UInt16
    public var paletteEntryIndex: UInt16

    public init(glyphID: UInt16, paletteEntryIndex: UInt16) {
        self.glyphID = glyphID
        self.paletteEntryIndex = paletteEntryIndex
    }

    /// True when this layer inherits the text run's foreground color (`0xFFFF`).
    public var usesForegroundColor: Bool {
        paletteEntryIndex == CPALTable.foregroundEntryIndex
    }
}

/// Parsed OpenType `COLR` v0 (Layered Color Glyphs) table.
public struct COLRTable: Equatable, Sendable {
    public struct BaseGlyphRecord: Equatable, Hashable, Sendable {
        public var glyphID: UInt16
        public var firstLayerIndex: UInt16
        public var numLayers: UInt16

        public init(glyphID: UInt16, firstLayerIndex: UInt16, numLayers: UInt16) {
            self.glyphID = glyphID
            self.firstLayerIndex = firstLayerIndex
            self.numLayers = numLayers
        }
    }

    public let version: UInt16
    public let numBaseGlyphRecords: Int
    public let baseGlyphRecordsOffset: Int
    public let layerRecordsOffset: Int
    public let numLayerRecords: Int
    public let baseGlyphRecords: [BaseGlyphRecord]
    public let layerRecords: [ColorGlyphLayer]

    /// Parses a binary OpenType `COLR` table starting at `offset` (v0 records; v1 headers are also accepted).
    public init?(data: [UInt8], offset: Int = 0, length: Int? = nil) {
        let limit = min(data.count, length.map { offset + $0 } ?? data.count)
        guard offset >= 0, offset + 14 <= limit else { return nil }

        let version = data.u16(at: offset)
        guard version == 0 || version == 1 else { return nil }

        let numBase = Int(data.u16(at: offset + 2))
        let baseOffset = Int(data.u32(at: offset + 4))
        let layerOffset = Int(data.u32(at: offset + 8))
        let numLayers = Int(data.u16(at: offset + 12))

        let baseStart = offset + baseOffset
        guard baseStart >= offset, baseStart + numBase * 6 <= limit else { return nil }

        let layerStart = offset + layerOffset
        guard layerStart >= offset, layerStart + numLayers * 4 <= limit else { return nil }

        var bases: [BaseGlyphRecord] = []
        bases.reserveCapacity(numBase)
        var isSorted = true
        var prevGlyph: UInt16 = 0
        for i in 0..<numBase {
            let p = baseStart + i * 6
            let gid = data.u16(at: p)
            let first = data.u16(at: p + 2)
            let count = data.u16(at: p + 4)
            if i > 0 && gid < prevGlyph { isSorted = false }
            prevGlyph = gid
            bases.append(BaseGlyphRecord(glyphID: gid, firstLayerIndex: first, numLayers: count))
        }
        if !isSorted {
            bases.sort { $0.glyphID < $1.glyphID }
        }

        var layers: [ColorGlyphLayer] = []
        layers.reserveCapacity(numLayers)
        for i in 0..<numLayers {
            let p = layerStart + i * 4
            let gid = data.u16(at: p)
            let palIdx = data.u16(at: p + 2)
            layers.append(ColorGlyphLayer(glyphID: gid, paletteEntryIndex: palIdx))
        }

        self.version = version
        self.numBaseGlyphRecords = numBase
        self.baseGlyphRecordsOffset = baseOffset
        self.layerRecordsOffset = layerOffset
        self.numLayerRecords = numLayers
        self.baseGlyphRecords = bases
        self.layerRecords = layers
    }

    /// Looks up the ordered layers for `baseGlyphID` using binary search on `baseGlyphRecords`.
    public func layers(for baseGlyphID: UInt16) -> [ColorGlyphLayer]? {
        var lo = 0
        var hi = baseGlyphRecords.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let rec = baseGlyphRecords[mid]
            if rec.glyphID == baseGlyphID {
                let start = Int(rec.firstLayerIndex)
                let end = min(layerRecords.count, start + Int(rec.numLayers))
                guard start <= end, start <= layerRecords.count else { return nil }
                return Array(layerRecords[start..<end])
            } else if rec.glyphID < baseGlyphID {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return nil
    }
}

/// Combined OpenType `COLR` v0 + `CPAL` color glyph table.
public struct ColorGlyphTable: Equatable, Sendable {
    public let colr: COLRTable
    public let cpal: CPALTable

    public init(colr: COLRTable, cpal: CPALTable) {
        self.colr = colr
        self.cpal = cpal
    }

    public init?(colrData: [UInt8], cpalData: [UInt8]) {
        guard let colr = COLRTable(data: colrData), let cpal = CPALTable(data: cpalData) else {
            return nil
        }
        self.colr = colr
        self.cpal = cpal
    }

    /// Resolves all layers of `baseGlyphID` into `(glyphID, color)` pairs in painter's order.
    public func resolvedLayers(
        for baseGlyphID: UInt16,
        palette: Int = 0,
        foreground: Color = .white
    ) -> [(glyphID: UInt16, color: Color)]? {
        guard let rawLayers = colr.layers(for: baseGlyphID) else { return nil }
        return rawLayers.map { layer in
            (
                glyphID: layer.glyphID,
                color: cpal.resolveColor(
                    paletteIndex: palette,
                    entryIndex: layer.paletteEntryIndex,
                    foreground: foreground
                )
            )
        }
    }

    /// Builds a valid binary OpenType `CPAL` v0 table from an array of palettes.
    public static func buildSyntheticCPAL(palettes: [[Color]]) -> [UInt8] {
        let numPalettes = palettes.count
        let numEntries = palettes.map(\.count).max() ?? 0
        let totalRecords = numPalettes * numEntries
        let colorRecordsOffset = 12 + numPalettes * 2

        var out: [UInt8] = []
        out.reserveCapacity(colorRecordsOffset + totalRecords * 4)
        out.append(u16: 0) // version 0
        out.append(u16: UInt16(numEntries))
        out.append(u16: UInt16(numPalettes))
        out.append(u16: UInt16(totalRecords))
        out.append(u32: UInt32(colorRecordsOffset))

        for p in 0..<numPalettes {
            out.append(u16: UInt16(p * numEntries))
        }

        for palette in palettes {
            for idx in 0..<numEntries {
                let c = idx < palette.count ? palette[idx] : .clear
                let b = UInt8(min(max((c.blue * 255.0).rounded(), 0.0), 255.0))
                let g = UInt8(min(max((c.green * 255.0).rounded(), 0.0), 255.0))
                let r = UInt8(min(max((c.red * 255.0).rounded(), 0.0), 255.0))
                let a = UInt8(min(max((c.opacity * 255.0).rounded(), 0.0), 255.0))
                out.append(b)
                out.append(g)
                out.append(r)
                out.append(a)
            }
        }
        return out
    }

    /// Builds a valid binary OpenType `COLR` v0 table from `(baseGlyphID, layers)` entries.
    /// Entries are sorted ascending by `baseGlyphID` per the OpenType specification.
    public static func buildSyntheticCOLR(
        glyphs: [(baseGlyphID: UInt16, layers: [ColorGlyphLayer])]
    ) -> [UInt8] {
        let sorted = glyphs.sorted { $0.baseGlyphID < $1.baseGlyphID }
        let baseOffset = 14
        let layerOffset = baseOffset + sorted.count * 6
        var flatLayers: [ColorGlyphLayer] = []
        var records: [COLRTable.BaseGlyphRecord] = []
        records.reserveCapacity(sorted.count)

        for entry in sorted {
            let firstIdx = UInt16(flatLayers.count)
            let count = UInt16(entry.layers.count)
            records.append(COLRTable.BaseGlyphRecord(
                glyphID: entry.baseGlyphID,
                firstLayerIndex: firstIdx,
                numLayers: count
            ))
            flatLayers.append(contentsOf: entry.layers)
        }

        var out: [UInt8] = []
        out.reserveCapacity(layerOffset + flatLayers.count * 4)
        out.append(u16: 0) // version 0
        out.append(u16: UInt16(records.count))
        out.append(u32: UInt32(baseOffset))
        out.append(u32: UInt32(layerOffset))
        out.append(u16: UInt16(flatLayers.count))

        for rec in records {
            out.append(u16: rec.glyphID)
            out.append(u16: rec.firstLayerIndex)
            out.append(u16: rec.numLayers)
        }
        for layer in flatLayers {
            out.append(u16: layer.glyphID)
            out.append(u16: layer.paletteEntryIndex)
        }
        return out
    }

    /// Builds matching synthetic binary `COLR` v0 and `CPAL` v0 tables for headless verification.
    public static func buildSyntheticTables(
        palettes: [[Color]],
        glyphs: [(baseGlyphID: UInt16, layers: [ColorGlyphLayer])]
    ) -> (colr: [UInt8], cpal: [UInt8]) {
        (
            colr: buildSyntheticCOLR(glyphs: glyphs),
            cpal: buildSyntheticCPAL(palettes: palettes)
        )
    }
}

extension FontFace {
    /// Parsed OpenType `COLR` v0 + `CPAL` color glyph table from this font face, if both tables exist.
    public var colorGlyphTable: ColorGlyphTable? {
        guard let colrLoc = table("COLR"), let cpalLoc = table("CPAL") else { return nil }
        guard let colr = COLRTable(data: data, offset: colrLoc.offset, length: colrLoc.length),
              let cpal = CPALTable(data: data, offset: cpalLoc.offset, length: cpalLoc.length) else {
            return nil
        }
        return ColorGlyphTable(colr: colr, cpal: cpal)
    }
}
