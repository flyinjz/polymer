// Pure-Swift text editing model: grapheme-indexed buffer, directional selection,
// undo/redo with typing-burst coalescing, IME marked text, and caret hit-testing.
import PolymerBase

/// A range of extended grapheme cluster offsets in a `TextBuffer`.
public struct TextRange: Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    @inlinable public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    @inlinable public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }

    @inlinable public init(location: Int, length: Int) {
        self.start = location
        self.end = location + length
    }

    public static let zero = TextRange(start: 0, end: 0)

    @inlinable public var lowerBound: Int { min(start, end) }
    @inlinable public var upperBound: Int { max(start, end) }
    @inlinable public var isEmpty: Bool { start == end }
    @inlinable public var count: Int { upperBound - lowerBound }
    @inlinable public var normalized: TextRange { TextRange(start: lowerBound, end: upperBound) }

    @inlinable public func clamped(to maxOffset: Int) -> TextRange {
        let hi = max(0, maxOffset)
        return TextRange(
            start: min(max(0, start), hi),
            end: min(max(0, end), hi)
        )
    }
}

/// A directional selection in a `TextBuffer`, preserving `anchor` and moving `head`
/// so Shift+Arrow extends and shrinks cleanly from the active end.
public struct TextSelection: Equatable, Hashable, Sendable {
    public var anchor: Int
    public var head: Int

    @inlinable public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    @inlinable public init(caret: Int) {
        self.anchor = caret
        self.head = caret
    }

    @inlinable public init(range: TextRange) {
        self.anchor = range.start
        self.head = range.end
    }

    public static let zero = TextSelection(caret: 0)

    @inlinable public var range: TextRange { TextRange(start: min(anchor, head), end: max(anchor, head)) }
    @inlinable public var isCollapsed: Bool { anchor == head }
    @inlinable public var caret: Int { head }

    @inlinable public func clamped(to maxOffset: Int) -> TextSelection {
        let hi = max(0, maxOffset)
        return TextSelection(
            anchor: min(max(0, anchor), hi),
            head: min(max(0, head), hi)
        )
    }
}

/// An active IME composition span inside a `TextBuffer`.
public struct MarkedText: Equatable, Hashable, Sendable {
    /// Span within the buffer (in grapheme offsets) occupied by the marked text.
    public var range: TextRange
    /// Current composition text.
    public var text: String
    /// Selection within `text` (in grapheme offsets relative to `range.lowerBound`).
    public var selectedRange: TextRange

    public init(range: TextRange, text: String, selectedRange: TextRange) {
        self.range = range
        self.text = text
        self.selectedRange = selectedRange
    }
}

/// Grapheme-cluster indexed text storage with word, line, and encoding conversion helpers.
public struct TextBuffer: Equatable, Sendable {
    public private(set) var text: String
    private var characters: [Character]

    public init(_ text: String = "") {
        self.text = text
        self.characters = Array(text)
    }

    public static func == (lhs: TextBuffer, rhs: TextBuffer) -> Bool {
        lhs.text == rhs.text
    }

    public var graphemeCount: Int { characters.count }
    public var isEmpty: Bool { characters.isEmpty }

    public subscript(offset: Int) -> Character {
        characters[offset]
    }

    public func slice(_ range: TextRange) -> String {
        let r = range.normalized.clamped(to: characters.count)
        guard r.lowerBound < r.upperBound else { return "" }
        return String(characters[r.lowerBound..<r.upperBound])
    }

    // MARK: Index and encoding conversions

    public func stringIndex(at graphemeOffset: Int) -> String.Index {
        let clamped = min(max(0, graphemeOffset), characters.count)
        return text.index(text.startIndex, offsetBy: clamped)
    }

    public func graphemeOffset(for stringIndex: String.Index) -> Int {
        let clamped = min(max(text.startIndex, stringIndex), text.endIndex)
        return text.distance(from: text.startIndex, to: clamped)
    }

    public func utf8Offset(at graphemeOffset: Int) -> Int {
        let idx = stringIndex(at: graphemeOffset)
        return text.utf8.distance(from: text.startIndex, to: idx)
    }

    public func graphemeOffset(forUTF8Offset utf8Offset: Int) -> Int {
        let clamped = min(max(0, utf8Offset), text.utf8.count)
        let target = text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
        var i = 0
        var cur = text.startIndex
        while cur < text.endIndex {
            let next = text.index(after: cur)
            if target < next { return i }
            cur = next
            i += 1
        }
        return i
    }

    public func utf16Offset(at graphemeOffset: Int) -> Int {
        let idx = stringIndex(at: graphemeOffset)
        return text.utf16.distance(from: text.startIndex, to: idx)
    }

    public func graphemeOffset(forUTF16Offset utf16Offset: Int) -> Int {
        let clamped = min(max(0, utf16Offset), text.utf16.count)
        let target = text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
        var i = 0
        var cur = text.startIndex
        while cur < text.endIndex {
            let next = text.index(after: cur)
            if target < next { return i }
            cur = next
            i += 1
        }
        return i
    }

    public func scalarOffset(at graphemeOffset: Int) -> Int {
        let idx = stringIndex(at: graphemeOffset)
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: idx)
    }

    public func graphemeOffset(forScalarOffset scalarOffset: Int) -> Int {
        let clamped = min(max(0, scalarOffset), text.unicodeScalars.count)
        let target = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: clamped)
        var i = 0
        var cur = text.startIndex
        while cur < text.endIndex {
            let next = text.index(after: cur)
            if target < next { return i }
            cur = next
            i += 1
        }
        return i
    }

    // MARK: Editing operations

    public mutating func insert(_ string: String, at offset: Int) {
        guard !string.isEmpty else { return }
        let pos = min(max(0, offset), characters.count)
        let idx = stringIndex(at: pos)
        text.insert(contentsOf: string, at: idx)
        characters.insert(contentsOf: string, at: pos)
    }

    public mutating func replace(_ range: TextRange, with string: String) {
        let r = range.normalized.clamped(to: characters.count)
        let lo = stringIndex(at: r.lowerBound)
        let hi = stringIndex(at: r.upperBound)
        text.replaceSubrange(lo..<hi, with: string)
        characters.replaceSubrange(r.lowerBound..<r.upperBound, with: string)
    }

    public mutating func delete(_ range: TextRange) {
        let r = range.normalized.clamped(to: characters.count)
        guard !r.isEmpty else { return }
        let lo = stringIndex(at: r.lowerBound)
        let hi = stringIndex(at: r.upperBound)
        text.removeSubrange(lo..<hi)
        characters.removeSubrange(r.lowerBound..<r.upperBound)
    }

    // MARK: Word boundaries

    private enum CharClass {
        case newline
        case whitespace
        case word
        case punctuation
    }

    private static func classify(_ ch: Character) -> CharClass {
        if ch.isNewline { return .newline }
        if ch.isWhitespace { return .whitespace }
        if ch.isLetter || ch.isNumber || ch == "_" { return .word }
        return .punctuation
    }

    /// Returns the grapheme offset of the start of the previous word from `offset`.
    public func previousWordBoundary(from offset: Int) -> Int {
        var i = min(max(0, offset), characters.count)
        guard i > 0 else { return 0 }

        // If immediately after a newline, step over a single newline.
        if Self.classify(characters[i - 1]) == .newline {
            return i - 1
        }

        // Skip horizontal whitespace before the target run.
        while i > 0, Self.classify(characters[i - 1]) == .whitespace {
            i -= 1
        }
        guard i > 0 else { return 0 }

        let targetClass = Self.classify(characters[i - 1])
        if targetClass == .newline {
            return i
        }
        while i > 0, Self.classify(characters[i - 1]) == targetClass {
            i -= 1
        }
        return i
    }

    /// Returns the grapheme offset of the end of the next word from `offset`.
    public func nextWordBoundary(from offset: Int) -> Int {
        let count = characters.count
        var i = min(max(0, offset), count)
        guard i < count else { return count }

        if Self.classify(characters[i]) == .newline {
            return i + 1
        }

        while i < count, Self.classify(characters[i]) == .whitespace {
            i += 1
        }
        guard i < count else { return count }

        let targetClass = Self.classify(characters[i])
        if targetClass == .newline {
            return i
        }
        while i < count, Self.classify(characters[i]) == targetClass {
            i += 1
        }
        return i
    }

    /// Returns the word range enclosing `offset` (for double-click word selection).
    public func wordRange(at offset: Int) -> TextRange {
        let count = characters.count
        guard count > 0 else { return .zero }
        let idx = min(max(0, offset), count - 1)
        let cls = Self.classify(characters[idx])
        if cls == .newline { return TextRange(idx, idx + 1) }
        var lo = idx
        while lo > 0, Self.classify(characters[lo - 1]) == cls { lo -= 1 }
        var hi = idx + 1
        while hi < count, Self.classify(characters[hi]) == cls { hi += 1 }
        return TextRange(start: lo, end: hi)
    }

    // MARK: Line boundaries

    public var lineCount: Int {
        var count = 1
        for ch in characters where ch.isNewline { count += 1 }
        return count
    }

    public func lineStart(from offset: Int) -> Int {
        var i = min(max(0, offset), characters.count)
        while i > 0, !characters[i - 1].isNewline { i -= 1 }
        return i
    }

    public func lineEnd(from offset: Int) -> Int {
        var i = min(max(0, offset), characters.count)
        while i < characters.count, !characters[i].isNewline { i += 1 }
        return i
    }

    public func lineIndex(of offset: Int) -> Int {
        let clamped = min(max(0, offset), characters.count)
        var line = 0
        for i in 0..<clamped where characters[i].isNewline { line += 1 }
        return line
    }

    public func columnIndex(of offset: Int) -> Int {
        let clamped = min(max(0, offset), characters.count)
        return clamped - lineStart(from: clamped)
    }

    public func lineRange(at lineIndex: Int) -> TextRange {
        let target = max(0, lineIndex)
        var currentLine = 0
        var start = 0
        for i in 0..<characters.count {
            if currentLine == target {
                var end = i
                while end < characters.count, !characters[end].isNewline { end += 1 }
                return TextRange(start: start, end: end)
            }
            if characters[i].isNewline {
                currentLine += 1
                start = i + 1
            }
        }
        return TextRange(start: start, end: characters.count)
    }

    public func offset(line: Int, column: Int) -> Int {
        let clampedLine = min(max(0, line), max(0, lineCount - 1))
        let range = lineRange(at: clampedLine)
        return min(range.start + max(0, column), range.end)
    }
}

// MARK: Shaped lines & caret hit-testing

/// A shaped visual line with grapheme-indexed caret positions for accurate
/// click hit-testing and selection geometry.
public struct ShapedLine: Hashable, Sendable {
    public var text: String
    public var glyphs: [PositionedGlyph]
    public var width: Double
    /// Grapheme range in the source buffer covered by this visual line.
    public var graphemeRange: TextRange
    /// X position (relative to line start) for each local grapheme offset `0...graphemeRange.count`.
    public var caretPositions: [Double]

    public init(text: String, glyphs: [PositionedGlyph], width: Double, graphemeRange: TextRange, caretPositions: [Double]) {
        self.text = text
        self.glyphs = glyphs
        self.width = width
        self.graphemeRange = graphemeRange
        self.caretPositions = caretPositions
    }

    /// Shapes a single line (without explicit newlines) and computes per-grapheme caret x positions.
    public static func shape(_ text: String, font: FontFace, pixelSize: Double, baseOffset: Int = 0) -> ShapedLine {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else {
            return ShapedLine(
                text: "",
                glyphs: [],
                width: 0,
                graphemeRange: TextRange(start: baseOffset, end: baseOffset),
                caretPositions: [0]
            )
        }

        // Map every Unicode scalar index within `text` to its grapheme index.
        var scalarToGrapheme: [Int] = []
        scalarToGrapheme.reserveCapacity(text.unicodeScalars.count)
        for (gi, ch) in chars.enumerated() {
            for _ in ch.unicodeScalars { scalarToGrapheme.append(gi) }
        }
        let totalScalars = scalarToGrapheme.count

        let glyphs = TextLayout.line(text, font: font, pixelSize: pixelSize)
        let totalWidth = TextLayout.width(glyphs)
        var positions = [Double](repeating: 0, count: n + 1)
        var assigned = [Bool](repeating: false, count: n + 1)
        assigned[0] = true
        positions[n] = totalWidth
        assigned[n] = true

        var idx = 0
        while idx < glyphs.count {
            let startCluster = min(max(0, glyphs[idx].cluster), max(0, totalScalars - 1))
            let gStart = scalarToGrapheme[startCluster]
            let startX = glyphs[idx].x

            // Group consecutive glyphs belonging to the same grapheme cluster.
            var endIdx = idx + 1
            while endIdx < glyphs.count {
                let nextCluster = min(max(0, glyphs[endIdx].cluster), max(0, totalScalars - 1))
                if scalarToGrapheme[nextCluster] != gStart { break }
                endIdx += 1
            }

            let gEnd: Int
            let endX: Double
            if endIdx < glyphs.count {
                let nextCluster = min(max(0, glyphs[endIdx].cluster), max(0, totalScalars - 1))
                gEnd = max(gStart + 1, scalarToGrapheme[nextCluster])
                endX = glyphs[endIdx].x
            } else {
                gEnd = n
                endX = totalWidth
            }

            if !assigned[gStart] {
                positions[gStart] = startX
                assigned[gStart] = true
            }

            // Subdivide ligature spans evenly across constituent graphemes.
            let span = gEnd - gStart
            if span > 1 {
                let adv = max(0, endX - startX)
                for step in 1..<span {
                    let g = gStart + step
                    if !assigned[g] {
                        positions[g] = startX + adv * Double(step) / Double(span)
                        assigned[g] = true
                    }
                }
            }
            idx = endIdx
        }

        // Fill any unassigned offsets monotonically.
        var lastX = 0.0
        for i in 0...n {
            if assigned[i] {
                lastX = max(lastX, positions[i])
                positions[i] = lastX
            } else {
                positions[i] = lastX
            }
        }

        return ShapedLine(
            text: text,
            glyphs: glyphs,
            width: totalWidth,
            graphemeRange: TextRange(start: baseOffset, end: baseOffset + n),
            caretPositions: positions
        )
    }

    /// Wraps multi-line text into visual `ShapedLine`s whose `graphemeRange`s correspond
    /// directly to grapheme offsets in `text`. Always returns at least one line.
    public static func wrap(_ text: String, font: FontFace, pixelSize: Double, maxWidth: Double?) -> [ShapedLine] {
        let chars = Array(text)
        var lines: [ShapedLine] = []
        var paraStart = 0

        while true {
            var paraEnd = paraStart
            while paraEnd < chars.count, !chars[paraEnd].isNewline { paraEnd += 1 }
            let isLastParagraph = paraEnd >= chars.count

            let paraChars = Array(chars[paraStart..<paraEnd])
            if paraChars.isEmpty {
                lines.append(ShapedLine(
                    text: "",
                    glyphs: [],
                    width: 0,
                    graphemeRange: TextRange(start: paraStart, end: paraStart),
                    caretPositions: [0]
                ))
            } else if let maxW = maxWidth, maxW.isFinite, maxW > 0 {
                let full = ShapedLine.shape(String(paraChars), font: font, pixelSize: pixelSize, baseOffset: paraStart)
                let m = paraChars.count
                var segStart = 0
                while segStart < m {
                    let x0 = full.caretPositions[segStart]
                    var i = segStart
                    var lastBreakAfter: Int? = nil
                    var segEnd = m

                    while i < m {
                        let ch = paraChars[i]
                        let isSpace = ch == " " || ch == "\t" || ch == "\u{200B}"
                        let nextX = full.caretPositions[i + 1] - x0
                        if !isSpace, nextX > maxW + 1e-9, i > segStart {
                            segEnd = lastBreakAfter ?? i
                            break
                        }
                        if isSpace {
                            var j = i + 1
                            while j < m, (paraChars[j] == " " || paraChars[j] == "\t" || paraChars[j] == "\u{200B}") {
                                j += 1
                            }
                            lastBreakAfter = j
                            i = j
                            continue
                        }
                        if ch == "-", i + 1 < m {
                            lastBreakAfter = i + 1
                        }
                        i += 1
                    }

                    let sliceStr = String(paraChars[segStart..<segEnd])
                    lines.append(ShapedLine.shape(sliceStr, font: font, pixelSize: pixelSize, baseOffset: paraStart + segStart))
                    segStart = segEnd
                }
            } else {
                lines.append(ShapedLine.shape(String(paraChars), font: font, pixelSize: pixelSize, baseOffset: paraStart))
            }

            if isLastParagraph { break }
            paraStart = paraEnd + 1
        }

        return lines
    }

    /// X position (points from line start) for a buffer-global grapheme `offset`.
    public func caretPosition(at offset: Int) -> Double {
        let local = min(max(0, offset - graphemeRange.lowerBound), caretPositions.count - 1)
        return caretPositions[local]
    }

    /// Buffer-global grapheme offset closest to `x` (points from line start).
    public func caretOffset(forX x: Double) -> Int {
        guard caretPositions.count > 1 else { return graphemeRange.lowerBound }
        if x <= caretPositions[0] { return graphemeRange.lowerBound }
        let lastIdx = caretPositions.count - 1
        if x >= caretPositions[lastIdx] { return graphemeRange.lowerBound + lastIdx }

        for i in 0..<lastIdx {
            let mid = (caretPositions[i] + caretPositions[i + 1]) * 0.5
            if x < mid { return graphemeRange.lowerBound + i }
        }
        return graphemeRange.lowerBound + lastIdx
    }
}

// MARK: TextEditorState

/// Complete pure-Swift editing state: buffer, directional selection, IME marked text,
/// and coalescing undo/redo history.
public struct TextEditorState: Equatable, Sendable {
    private enum CoalescingKind: Equatable, Sendable {
        case none
        case insert
        case deleteBackward
        case deleteForward
    }

    private struct Snapshot: Equatable, Sendable {
        var buffer: TextBuffer
        var selection: TextSelection
    }

    public var buffer: TextBuffer
    public var selection: TextSelection
    public var markedText: MarkedText?
    public var undoLimit: Int

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCoalescing: CoalescingKind = .none
    private var lastPostEditCaret: Int = -1
    private var preferredColumn: Int? = nil
    /// Snapshot captured when an IME composition session begins, so cancel restores
    /// the original buffer and commit records a single clean undo entry.
    private var preMarkedSnapshot: Snapshot? = nil

    public init(_ text: String = "", undoLimit: Int = 200) {
        let buf = TextBuffer(text)
        self.buffer = buf
        self.selection = TextSelection(caret: buf.graphemeCount)
        self.markedText = nil
        self.undoLimit = max(1, undoLimit)
    }

    public static func == (lhs: TextEditorState, rhs: TextEditorState) -> Bool {
        lhs.buffer == rhs.buffer
            && lhs.selection == rhs.selection
            && lhs.markedText == rhs.markedText
            && lhs.undoLimit == rhs.undoLimit
            && lhs.undoStack == rhs.undoStack
            && lhs.redoStack == rhs.redoStack
    }

    /// Plain text view of the buffer. Setting externally replaces the buffer, clears
    /// any active marked text, and clamps the selection.
    public var text: String {
        get { buffer.text }
        set {
            guard newValue != buffer.text else { return }
            buffer = TextBuffer(newValue)
            markedText = nil
            preMarkedSnapshot = nil
            selection = selection.clamped(to: buffer.graphemeCount)
            lastCoalescing = .none
            preferredColumn = nil
        }
    }

    // MARK: Undo / Redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func breakUndoCoalescing() {
        lastCoalescing = .none
        lastPostEditCaret = -1
    }

    private mutating func pushUndoSnapshot(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    public mutating func undo() {
        if markedText != nil { cancelMarkedText() }
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(Snapshot(buffer: buffer, selection: selection))
        buffer = prev.buffer
        selection = prev.selection.clamped(to: buffer.graphemeCount)
        breakUndoCoalescing()
        preferredColumn = nil
    }

    public mutating func redo() {
        if markedText != nil { cancelMarkedText() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(buffer: buffer, selection: selection))
        buffer = next.buffer
        selection = next.selection.clamped(to: buffer.graphemeCount)
        breakUndoCoalescing()
        preferredColumn = nil
    }

    // MARK: Editing

    public mutating func insertText(_ string: String) {
        if markedText != nil {
            commitMarkedText(string)
            return
        }
        guard !string.isEmpty else { return }
        let insertedCount = string.count
        let isSingleNonNewline = insertedCount == 1 && !(string.first?.isNewline ?? true)
        let shouldCoalesce = isSingleNonNewline
            && selection.isCollapsed
            && lastCoalescing == .insert
            && selection.head == lastPostEditCaret
            && !undoStack.isEmpty

        if !shouldCoalesce {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
        } else {
            redoStack.removeAll(keepingCapacity: true)
        }

        let range = selection.range
        buffer.replace(range, with: string)
        let newCaret = range.lowerBound + insertedCount
        selection = TextSelection(caret: newCaret)
        preferredColumn = nil

        if isSingleNonNewline {
            lastCoalescing = .insert
            lastPostEditCaret = newCaret
        } else {
            breakUndoCoalescing()
        }
    }

    public mutating func replaceSelection(with string: String) {
        if markedText != nil {
            commitMarkedText(string)
            return
        }
        pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
        let range = selection.range
        buffer.replace(range, with: string)
        let newCaret = range.lowerBound + string.count
        selection = TextSelection(caret: newCaret)
        preferredColumn = nil
        breakUndoCoalescing()
    }

    public mutating func deleteBackward(byWord: Bool = false) {
        if markedText != nil {
            cancelMarkedText()
            return
        }
        if !selection.isCollapsed {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
            let r = selection.range
            buffer.delete(r)
            selection = TextSelection(caret: r.lowerBound)
            preferredColumn = nil
            breakUndoCoalescing()
            return
        }
        guard selection.head > 0 else { return }
        let target = byWord ? buffer.previousWordBoundary(from: selection.head) : selection.head - 1
        guard target < selection.head else { return }

        let shouldCoalesce = !byWord
            && lastCoalescing == .deleteBackward
            && selection.head == lastPostEditCaret
            && !undoStack.isEmpty

        if !shouldCoalesce {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
        } else {
            redoStack.removeAll(keepingCapacity: true)
        }

        buffer.delete(TextRange(start: target, end: selection.head))
        selection = TextSelection(caret: target)
        preferredColumn = nil

        if !byWord {
            lastCoalescing = .deleteBackward
            lastPostEditCaret = target
        } else {
            breakUndoCoalescing()
        }
    }

    public mutating func deleteForward(byWord: Bool = false) {
        if markedText != nil {
            cancelMarkedText()
            return
        }
        if !selection.isCollapsed {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
            let r = selection.range
            buffer.delete(r)
            selection = TextSelection(caret: r.lowerBound)
            preferredColumn = nil
            breakUndoCoalescing()
            return
        }
        guard selection.head < buffer.graphemeCount else { return }
        let target = byWord ? buffer.nextWordBoundary(from: selection.head) : selection.head + 1
        guard target > selection.head else { return }

        let shouldCoalesce = !byWord
            && lastCoalescing == .deleteForward
            && selection.head == lastPostEditCaret
            && !undoStack.isEmpty

        if !shouldCoalesce {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
        } else {
            redoStack.removeAll(keepingCapacity: true)
        }

        buffer.delete(TextRange(start: selection.head, end: target))
        selection = TextSelection(caret: selection.head)
        preferredColumn = nil

        if !byWord {
            lastCoalescing = .deleteForward
            lastPostEditCaret = selection.head
        } else {
            breakUndoCoalescing()
        }
    }

    // MARK: Navigation

    public mutating func setCaret(_ offset: Int, extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        let clamped = min(max(0, offset), buffer.graphemeCount)
        if extendingSelection {
            selection.head = clamped
        } else {
            selection = TextSelection(caret: clamped)
        }
        preferredColumn = nil
        breakUndoCoalescing()
    }

    public mutating func moveLeft(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        if !extendingSelection && !selection.isCollapsed {
            selection = TextSelection(caret: selection.range.lowerBound)
            return
        }
        let target = max(0, selection.head - 1)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveRight(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        if !extendingSelection && !selection.isCollapsed {
            selection = TextSelection(caret: selection.range.upperBound)
            return
        }
        let target = min(buffer.graphemeCount, selection.head + 1)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveWordLeft(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let target = buffer.previousWordBoundary(from: selection.head)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveWordRight(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let target = buffer.nextWordBoundary(from: selection.head)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveToLineStart(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let target = buffer.lineStart(from: selection.head)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveToLineEnd(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let target = buffer.lineEnd(from: selection.head)
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveUp(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        let line = buffer.lineIndex(of: selection.head)
        let col = preferredColumn ?? buffer.columnIndex(of: selection.head)
        let target: Int
        if line > 0 {
            preferredColumn = col
            target = buffer.offset(line: line - 1, column: col)
        } else {
            preferredColumn = 0
            target = 0
        }
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveDown(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        let line = buffer.lineIndex(of: selection.head)
        let col = preferredColumn ?? buffer.columnIndex(of: selection.head)
        let target: Int
        if line + 1 < buffer.lineCount {
            preferredColumn = col
            target = buffer.offset(line: line + 1, column: col)
        } else {
            preferredColumn = nil
            target = buffer.graphemeCount
        }
        if extendingSelection {
            selection.head = target
        } else {
            selection = TextSelection(caret: target)
        }
    }

    public mutating func moveToDocumentStart(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        if extendingSelection {
            selection.head = 0
        } else {
            selection = TextSelection(caret: 0)
        }
    }

    public mutating func moveToDocumentEnd(extendingSelection: Bool = false) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let end = buffer.graphemeCount
        if extendingSelection {
            selection.head = end
        } else {
            selection = TextSelection(caret: end)
        }
    }

    public mutating func selectAll() {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        selection = TextSelection(anchor: 0, head: buffer.graphemeCount)
    }

    public mutating func selectWord(at offset: Int) {
        if markedText != nil { commitMarkedText() }
        breakUndoCoalescing()
        preferredColumn = nil
        let r = buffer.wordRange(at: offset)
        selection = TextSelection(anchor: r.start, head: r.end)
    }

    // MARK: IME Marked Text

    /// Begins or updates an IME composition span. Passing an empty string cancels composition.
    public mutating func setMarkedText(_ text: String, selectedRange: TextRange? = nil) {
        if text.isEmpty {
            cancelMarkedText()
            return
        }
        breakUndoCoalescing()
        preferredColumn = nil

        let replaceRange: TextRange
        if let existing = markedText {
            replaceRange = existing.range
        } else {
            preMarkedSnapshot = Snapshot(buffer: buffer, selection: selection)
            replaceRange = selection.range
        }

        let len = text.count
        buffer.replace(replaceRange, with: text)
        let newMarkedRange = TextRange(start: replaceRange.lowerBound, end: replaceRange.lowerBound + len)
        let selInMarked = (selectedRange ?? TextRange(start: len, end: len)).clamped(to: len)
        markedText = MarkedText(range: newMarkedRange, text: text, selectedRange: selInMarked)
        selection = TextSelection(
            anchor: newMarkedRange.lowerBound + selInMarked.start,
            head: newMarkedRange.lowerBound + selInMarked.end
        )
    }

    /// Commits the current marked text (or replaces it with `committedText` when provided).
    public mutating func commitMarkedText(_ committedText: String? = nil) {
        guard let current = markedText else {
            if let text = committedText, !text.isEmpty { insertText(text) }
            return
        }
        let finalString = committedText ?? current.text
        if let pre = preMarkedSnapshot {
            pushUndoSnapshot(pre)
            preMarkedSnapshot = nil
        } else {
            pushUndoSnapshot(Snapshot(buffer: buffer, selection: selection))
        }
        buffer.replace(current.range, with: finalString)
        let caret = current.range.lowerBound + finalString.count
        selection = TextSelection(caret: caret)
        markedText = nil
        preferredColumn = nil
        breakUndoCoalescing()
    }

    /// Cancels an active IME composition and restores the pre-composition buffer and selection.
    public mutating func cancelMarkedText() {
        guard let current = markedText else { return }
        if let pre = preMarkedSnapshot {
            buffer = pre.buffer
            selection = pre.selection.clamped(to: buffer.graphemeCount)
            preMarkedSnapshot = nil
        } else {
            buffer.delete(current.range)
            selection = TextSelection(caret: current.range.lowerBound)
        }
        markedText = nil
        preferredColumn = nil
        breakUndoCoalescing()
    }

    // MARK: Clipboard helpers

    public var selectedText: String {
        buffer.slice(selection.range)
    }

    public mutating func copy() -> String? {
        selection.isCollapsed ? nil : selectedText
    }

    public mutating func cut() -> String? {
        guard !selection.isCollapsed else { return nil }
        let taken = selectedText
        deleteBackward()
        return taken
    }

    public mutating func paste(_ text: String) {
        replaceSelection(with: text)
    }

    // MARK: Hit-testing helpers

    public func caretPosition(at offset: Int, in line: ShapedLine) -> Double {
        line.caretPosition(at: offset)
    }

    public func caretOffset(forX x: Double, in line: ShapedLine) -> Int {
        line.caretOffset(forX: x)
    }

    public func caretPosition(at offset: Int, font: FontFace, size: Double) -> Double {
        let line = ShapedLine.shape(buffer.text, font: font, pixelSize: size, baseOffset: 0)
        return line.caretPosition(at: offset)
    }

    public func caretOffset(forX x: Double, font: FontFace, size: Double) -> Int {
        let line = ShapedLine.shape(buffer.text, font: font, pixelSize: size, baseOffset: 0)
        return line.caretOffset(forX: x)
    }
}
