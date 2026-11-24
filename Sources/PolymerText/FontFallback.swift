// Font fallback chain: resolves missing glyphs across an ordered list of
// FontFace instances and shapes text into minimal contiguous runs with
// continuous horizontal advance across run boundaries.
import PolymerBase

/// Ordered font fallback chain (`faces[0]` is the primary face).
public struct FontFallbackChain: Sendable {
    /// A single contiguous shaped run resolved to one face in the chain.
    public struct ShapedRun: Equatable, Hashable, Sendable {
        public let faceIndex: Int
        public let text: String
        public let glyphs: [PositionedGlyph]

        public init(faceIndex: Int, text: String, glyphs: [PositionedGlyph]) {
            self.faceIndex = faceIndex
            self.text = text
            self.glyphs = glyphs
        }

        /// Total horizontal advance of the run (or 0 if empty).
        public var width: Double {
            guard let first = glyphs.first, let last = glyphs.last else { return 0 }
            return (last.x + last.advance) - first.x
        }
    }

    public let faces: [FontFace]

    public init(_ faces: [FontFace]) {
        self.faces = faces
    }

    public init(primary: FontFace, fallbacks: [FontFace] = []) {
        var all: [FontFace] = [primary]
        all.append(contentsOf: fallbacks)
        self.faces = all
    }

    /// Resolves `scalar` to the first face in the chain whose `cmap` contains a
    /// non-zero glyph ID, falling back to the primary face's `.notdef` (0) if
    /// no face covers the scalar. Returns `nil` only when the chain is empty.
    public func resolve(scalar: Unicode.Scalar) -> (face: FontFace, glyphID: UInt16)? {
        guard let hit = resolveIndex(scalar: scalar) else { return nil }
        return (faces[hit.faceIndex], hit.glyphID)
    }

    /// Same as `resolve(scalar:)`, returning the index into `faces` instead of the face itself.
    public func resolveIndex(scalar: Unicode.Scalar) -> (faceIndex: Int, glyphID: UInt16)? {
        guard !faces.isEmpty else { return nil }
        for (index, face) in faces.enumerated() {
            let gid = face.glyph(for: scalar)
            if gid != 0 {
                return (index, gid)
            }
        }
        return (0, 0)
    }

    /// Shapes `text` at `size` (pixels per em) into minimal contiguous runs.
    /// Kerning and GSUB substitutions are preserved within each run, and
    /// glyph `x` coordinates advance continuously across run boundaries.
    public func shape(_ text: String, size: Double) -> [ShapedRun] {
        guard !faces.isEmpty, !text.isEmpty else { return [] }
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        // Assign each scalar to its resolved face index, keeping combining marks
        // attached to the previous face when that face also maps the mark.
        var assignments: [Int] = []
        assignments.reserveCapacity(scalars.count)
        for s in scalars {
            if let prev = assignments.last,
               UnicodeLineBreak.lineBreakClass(for: s) == .CM,
               faces[prev].glyph(for: s) != 0 {
                assignments.append(prev)
            } else {
                assignments.append(resolveIndex(scalar: s)?.faceIndex ?? 0)
            }
        }

        // Partition into minimal contiguous runs and shape each with continuous x-advance.
        var runs: [ShapedRun] = []
        var cursorX = 0.0
        var start = 0
        while start < scalars.count {
            let faceIndex = assignments[start]
            var end = start + 1
            while end < scalars.count, assignments[end] == faceIndex {
                end += 1
            }

            let slice = scalars[start..<end]
            let rawGlyphs = TextLayout.line(slice, font: faces[faceIndex], pixelSize: size)
            var positioned: [PositionedGlyph] = []
            positioned.reserveCapacity(rawGlyphs.count)
            for g in rawGlyphs {
                positioned.append(PositionedGlyph(
                    glyph: g.glyph,
                    x: cursorX + g.x,
                    advance: g.advance,
                    cluster: start + g.cluster
                ))
            }
            if let last = positioned.last {
                cursorX = last.x + last.advance
            }

            let runText = String(String.UnicodeScalarView(slice))
            runs.append(ShapedRun(faceIndex: faceIndex, text: runText, glyphs: positioned))
            start = end
        }
        return runs
    }
}
