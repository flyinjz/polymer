// Single-line `TextField` and multi-line `TextEditor`, backed by `PolymerText.TextEditorState`.
import PolymerBase
import PolymerText
import PolymerRender

/// Internal protocol for pointer caret placement and drag selection in text controls.
@MainActor
protocol TextEditableNode: Node {
    var isTextEditableEnabled: Bool { get }
    func textPointerDown(at screenPoint: Point)
    func textPointerDragged(to screenPoint: Point)
    func textPointerUp(at screenPoint: Point)
}

private enum TextControlBinding {
    case string(Binding<String>)
    case state(Binding<TextEditorState>)
}

/// Filters a key press's characters down to printable text (excluding control codes and PUA key codes).
private func printableCharacters(from press: KeyPress) -> String {
    guard !press.characters.isEmpty else { return "" }
    var out = ""
    for scalar in press.characters.unicodeScalars {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (v >= 0xF700 && v <= 0xF8FF) { continue }
        out.unicodeScalars.append(scalar)
    }
    return out
}

// MARK: TextField

/// A single-line editable text control with placeholder, caret, selection,
/// horizontal scrolling, undo/redo, and IME marked-text rendering.
public struct TextField: View, PrimitiveView {
    let placeholder: String
    private let binding: TextControlBinding
    let onSubmit: (@MainActor () -> Void)?

    public init(_ placeholder: String = "", text: Binding<String>, onSubmit: (@MainActor () -> Void)? = nil) {
        self.placeholder = placeholder
        self.binding = .string(text)
        self.onSubmit = onSubmit
    }

    public init(_ placeholder: String = "", state: Binding<TextEditorState>, onSubmit: (@MainActor () -> Void)? = nil) {
        self.placeholder = placeholder
        self.binding = .state(state)
        self.onSubmit = onSubmit
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TextFieldNode) ?? TextFieldNode()
        let e = c.environment
        n.placeholder = placeholder
        n.font = e.font
        n.color = e.foregroundColor
        n.options = e.textRendering
        n.isEnabled = e.isEnabled
        n.onSubmit = onSubmit
        n.tree = c.tree

        switch binding {
        case .string(let b):
            let external = b.wrappedValue
            if external != n.editorState.text {
                n.editorState.text = external
                n.invalidateShapedLine()
            }
            n.writeBack = { st in
                if b.wrappedValue != st.text { b.wrappedValue = st.text }
            }
        case .state(let b):
            let external = b.wrappedValue
            if external != n.editorState {
                n.editorState = external
                n.invalidateShapedLine()
            }
            n.writeBack = { st in
                if b.wrappedValue != st { b.wrappedValue = st }
            }
        }
        return n
    }
}

final class TextFieldNode: Node, TextEditableNode {
    var placeholder: String = ""
    var editorState = TextEditorState()
    var writeBack: (@MainActor (TextEditorState) -> Void)?
    var onSubmit: (@MainActor () -> Void)?
    var font: Font? {
        didSet { if font != oldValue { invalidateShapedLine() } }
    }
    var color: Color = .white
    var options: TextRenderingOptions = .standard
    var isEnabled: Bool = true
    weak var tree: TreeState?

    private(set) var scrollOffsetX: Double = 0
    private var cachedLineText: String = ""
    private var cachedLine: ShapedLine?
    private let insetX: Double = 2
    private let caretWidth: Double = 1

    override var role: String { "TextField" }
    override var detail: String { "\"\(editorState.text)\"" }
    override var acceptsFocus: Bool { isEnabled }
    override var focusesOnClick: Bool { isEnabled }
    override var isHitTarget: Bool { true }
    override var clipsContent: Bool { true }
    var isTextEditableEnabled: Bool { isEnabled }
    var isFocused: Bool { tree?.focused === self }

    func invalidateShapedLine() {
        cachedLine = nil
    }

    private func ceilToPixel(_ v: Double) -> Double { (v * scale).rounded(.up) / scale }

    private func lineHeight(_ font: Font) -> Double { ceilToPixel(font.lineHeight) }

    func shapedLine() -> ShapedLine? {
        guard let font else { return nil }
        let currentText = editorState.text
        if let cachedLine, cachedLineText == currentText { return cachedLine }
        let line = ShapedLine.shape(currentText, font: font.face, pixelSize: font.size, baseOffset: 0)
        cachedLineText = currentText
        cachedLine = line
        return line
    }

    private func ensureCaretVisible() {
        guard let line = shapedLine(), frame.width > 0 else { return }
        let caretX = line.caretPosition(at: editorState.selection.caret)
        let visibleWidth = max(1, frame.width - 2 * insetX)
        if caretX < scrollOffsetX {
            scrollOffsetX = caretX
        } else if caretX + caretWidth > scrollOffsetX + visibleWidth {
            scrollOffsetX = caretX + caretWidth - visibleWidth
        }
        let maxScroll = max(0, line.width + caretWidth - visibleWidth)
        scrollOffsetX = min(max(0, scrollOffsetX), maxScroll)
    }

    private func commitChange() {
        invalidateShapedLine()
        ensureCaretVisible()
        writeBack?(editorState)
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let h = font.map { lineHeight($0) } ?? 20
        let idealW: Double
        if let font {
            let sample = editorState.text.isEmpty ? placeholder : editorState.text
            let w = TextLayout.width(TextLayout.line(sample, font: font.face, pixelSize: font.size))
            idealW = max(100, ceilToPixel(w + 2 * insetX + caretWidth))
        } else {
            idealW = 100
        }
        let w = p.width.flatMap { $0.isFinite ? $0 : nil } ?? idealW
        return Size(width: w, height: h)
    }

    override func placeChildren(in rect: Rect) {
        ensureCaretVisible()
    }

    // MARK: Pointer

    func textPointerDown(at screenPoint: Point) {
        guard isEnabled, let line = shapedLine() else { return }
        let localX = screenPoint.x - screenFrame.minX - insetX + scrollOffsetX
        let offset = line.caretOffset(forX: localX)
        editorState.setCaret(offset, extendingSelection: false)
        commitChange()
    }

    func textPointerDragged(to screenPoint: Point) {
        guard isEnabled, let line = shapedLine() else { return }
        let localX = screenPoint.x - screenFrame.minX - insetX + scrollOffsetX
        let offset = line.caretOffset(forX: localX)
        editorState.setCaret(offset, extendingSelection: true)
        commitChange()
    }

    func textPointerUp(at screenPoint: Point) {}

    // MARK: Keyboard

    override func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled, press.phase == .down || press.phase == .repeat else { return .ignored }
        let mods = press.modifiers
        let shift = mods.contains(.shift)
        let cmd = mods.contains(.command)
        let ctrl = mods.contains(.control)
        let option = mods.contains(.option)
        let cmdOrCtrl = cmd || ctrl
        let wordMod = option || ctrl

        if cmdOrCtrl {
            switch press.key {
            case "a":
                editorState.selectAll()
                commitChange()
                return .handled
            case "z":
                if shift { editorState.redo() } else { editorState.undo() }
                commitChange()
                return .handled
            case "y":
                editorState.redo()
                commitChange()
                return .handled
            case .leftArrow:
                if cmd { editorState.moveToLineStart(extendingSelection: shift) }
                else { editorState.moveWordLeft(extendingSelection: shift) }
                commitChange()
                return .handled
            case .rightArrow:
                if cmd { editorState.moveToLineEnd(extendingSelection: shift) }
                else { editorState.moveWordRight(extendingSelection: shift) }
                commitChange()
                return .handled
            case .delete:
                editorState.deleteBackward(byWord: true)
                commitChange()
                return .handled
            case .deleteForward:
                editorState.deleteForward(byWord: true)
                commitChange()
                return .handled
            default:
                return .ignored
            }
        }

        switch press.key {
        case .tab:
            return .ignored
        case .escape:
            if editorState.markedText != nil {
                editorState.cancelMarkedText()
                commitChange()
                return .handled
            }
            return .ignored
        case .return:
            if editorState.markedText != nil {
                editorState.commitMarkedText()
                commitChange()
            } else {
                onSubmit?()
            }
            return .handled
        case .leftArrow:
            if wordMod { editorState.moveWordLeft(extendingSelection: shift) }
            else { editorState.moveLeft(extendingSelection: shift) }
            commitChange()
            return .handled
        case .rightArrow:
            if wordMod { editorState.moveWordRight(extendingSelection: shift) }
            else { editorState.moveRight(extendingSelection: shift) }
            commitChange()
            return .handled
        case .upArrow:
            editorState.moveToLineStart(extendingSelection: shift)
            commitChange()
            return .handled
        case .downArrow:
            editorState.moveToLineEnd(extendingSelection: shift)
            commitChange()
            return .handled
        case .home:
            editorState.moveToLineStart(extendingSelection: shift)
            commitChange()
            return .handled
        case .end:
            editorState.moveToLineEnd(extendingSelection: shift)
            commitChange()
            return .handled
        case .delete:
            editorState.deleteBackward(byWord: wordMod)
            commitChange()
            return .handled
        case .deleteForward:
            editorState.deleteForward(byWord: wordMod)
            commitChange()
            return .handled
        default:
            let chars = printableCharacters(from: press)
            guard !chars.isEmpty else { return .ignored }
            editorState.insertText(chars)
            commitChange()
            return .handled
        }
    }

    // MARK: Drawing

    override func draw(_ list: inout DisplayList) {
        guard let font, list.isVisible(frame) else { return }
        let lh = lineHeight(font)
        let lineTop = frame.minY + (frame.height - lh) / 2
        let baseline = ((lineTop + (lh - font.lineHeight) / 2 + font.ascent) * scale).rounded() / scale
        let originX = frame.minX + insetX - scrollOffsetX
        let effectiveColor = isEnabled ? color : color.opacity(0.45)

        list.clipped(to: frame) { c in
            if editorState.text.isEmpty {
                if !placeholder.isEmpty {
                    let phGlyphs = TextLayout.line(placeholder, font: font.face, pixelSize: font.size)
                    let px = ((frame.minX + insetX) * scale).rounded() / scale
                    c.drawGlyphs(phGlyphs, font: font.face, size: font.size, at: Point(x: px, y: baseline),
                                 color: effectiveColor.opacity(0.42), options: options)
                }
            } else if let line = shapedLine() {
                if !editorState.selection.isCollapsed {
                    let sel = editorState.selection.range
                    let x0 = originX + line.caretPosition(at: sel.lowerBound)
                    let x1 = originX + line.caretPosition(at: sel.upperBound)
                    let selRect = Rect(x: x0, y: lineTop, width: max(1, x1 - x0), height: lh)
                    c.fill(selRect, effectiveColor.opacity(isFocused ? 0.28 : 0.14))
                }
                let tx = (originX * scale).rounded() / scale
                c.drawGlyphs(line.glyphs, font: font.face, size: font.size, at: Point(x: tx, y: baseline),
                             color: effectiveColor, options: options)
                if let marked = editorState.markedText, !marked.range.isEmpty {
                    let mx0 = originX + line.caretPosition(at: marked.range.lowerBound)
                    let mx1 = originX + line.caretPosition(at: marked.range.upperBound)
                    let underlineY = min(frame.maxY - 1, baseline + 2)
                    c.fill(Rect(x: mx0, y: underlineY, width: max(1, mx1 - mx0), height: 1), effectiveColor.opacity(0.85))
                }
            }

            if isFocused, isEnabled, let line = shapedLine() {
                let cx = ((originX + line.caretPosition(at: editorState.selection.caret)) * scale).rounded() / scale
                c.fill(Rect(x: cx, y: lineTop, width: caretWidth, height: lh), effectiveColor)
            }
        }
    }
}

// MARK: TextEditor

/// A multi-line editable text view with word wrapping, multi-line selection,
/// Up/Down/Return editing, undo/redo, IME marked text, and vertical scrolling.
public struct TextEditor: View, PrimitiveView {
    private let binding: TextControlBinding

    public init(text: Binding<String>) {
        self.binding = .string(text)
    }

    public init(state: Binding<TextEditorState>) {
        self.binding = .state(state)
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TextEditorNode) ?? TextEditorNode()
        let e = c.environment
        n.font = e.font
        n.color = e.foregroundColor
        n.options = e.textRendering
        n.isEnabled = e.isEnabled
        n.tree = c.tree

        switch binding {
        case .string(let b):
            let external = b.wrappedValue
            if external != n.editorState.text {
                n.editorState.text = external
                n.invalidateWrappedLines()
            }
            n.writeBack = { st in
                if b.wrappedValue != st.text { b.wrappedValue = st.text }
            }
        case .state(let b):
            let external = b.wrappedValue
            if external != n.editorState {
                n.editorState = external
                n.invalidateWrappedLines()
            }
            n.writeBack = { st in
                if b.wrappedValue != st { b.wrappedValue = st }
            }
        }
        return n
    }
}

final class TextEditorNode: Node, TextEditableNode {
    var editorState = TextEditorState()
    var writeBack: (@MainActor (TextEditorState) -> Void)?
    var font: Font? {
        didSet { if font != oldValue { invalidateWrappedLines() } }
    }
    var color: Color = .white
    var options: TextRenderingOptions = .standard
    var isEnabled: Bool = true
    weak var tree: TreeState?

    private(set) var scrollOffsetY: Double = 0
    private var cachedText: String = ""
    private var cachedWrapWidth: Double? = nil
    private var cachedLines: [ShapedLine]? = nil
    private let insetX: Double = 2
    private let insetY: Double = 2
    private let caretWidth: Double = 1

    override var role: String { "TextEditor" }
    override var detail: String { "\"\(editorState.text)\"" }
    override var acceptsFocus: Bool { isEnabled }
    override var focusesOnClick: Bool { isEnabled }
    override var isHitTarget: Bool { true }
    override var clipsContent: Bool { true }
    var isTextEditableEnabled: Bool { isEnabled }
    var isFocused: Bool { tree?.focused === self }

    func invalidateWrappedLines() {
        cachedLines = nil
    }

    private func ceilToPixel(_ v: Double) -> Double { (v * scale).rounded(.up) / scale }
    private func lineHeight(_ font: Font) -> Double { ceilToPixel(font.lineHeight) }

    func wrappedLines(forWidth width: Double?) -> [ShapedLine] {
        guard let font else { return [] }
        let wrapW = width.flatMap { $0.isFinite ? max(1, $0 - 2 * insetX) : nil }
        let currentText = editorState.text
        if let cachedLines, cachedText == currentText, cachedWrapWidth == wrapW {
            return cachedLines
        }
        let lines = ShapedLine.wrap(currentText, font: font.face, pixelSize: font.size, maxWidth: wrapW)
        cachedText = currentText
        cachedWrapWidth = wrapW
        cachedLines = lines
        return lines
    }

    private func visualLineIndex(for offset: Int, in lines: [ShapedLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        for (i, line) in lines.enumerated() {
            if offset < line.graphemeRange.upperBound {
                return i
            }
            if offset == line.graphemeRange.upperBound {
                // If the next line starts at the exact same offset (soft wrap), advance to next line.
                if i + 1 < lines.count, lines[i + 1].graphemeRange.lowerBound == offset {
                    continue
                }
                return i
            }
        }
        return lines.count - 1
    }

    private func ensureCaretVisible() {
        guard let font, frame.height > 0 else { return }
        let lh = lineHeight(font)
        let lines = wrappedLines(forWidth: frame.width)
        let lineIdx = visualLineIndex(for: editorState.selection.caret, in: lines)
        let caretTop = Double(lineIdx) * lh
        let caretBottom = caretTop + lh
        let visibleHeight = max(lh, frame.height - 2 * insetY)
        if caretTop < scrollOffsetY {
            scrollOffsetY = caretTop
        } else if caretBottom > scrollOffsetY + visibleHeight {
            scrollOffsetY = caretBottom - visibleHeight
        }
        let totalHeight = Double(lines.count) * lh
        let maxScroll = max(0, totalHeight - visibleHeight)
        scrollOffsetY = min(max(0, scrollOffsetY), maxScroll)
    }

    private func commitChange() {
        invalidateWrappedLines()
        ensureCaretVisible()
        writeBack?(editorState)
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let lh = font.map { lineHeight($0) } ?? 20
        let w = p.width.flatMap { $0.isFinite ? $0 : nil } ?? 200
        let lines = wrappedLines(forWidth: w)
        let contentH = max(lh * 3, Double(lines.count) * lh + 2 * insetY)
        let h = p.height.flatMap { $0.isFinite ? $0 : nil } ?? contentH
        return Size(width: w, height: h)
    }

    override func placeChildren(in rect: Rect) {
        ensureCaretVisible()
    }

    // MARK: Pointer

    private func offsetForPoint(_ screenPoint: Point) -> Int? {
        guard let font else { return nil }
        let lines = wrappedLines(forWidth: frame.width)
        guard !lines.isEmpty else { return 0 }
        let lh = lineHeight(font)
        let localX = screenPoint.x - screenFrame.minX - insetX
        let localY = screenPoint.y - screenFrame.minY - insetY + scrollOffsetY
        let lineIdx = min(max(0, Int((localY / lh).rounded(.down))), lines.count - 1)
        return lines[lineIdx].caretOffset(forX: localX)
    }

    func textPointerDown(at screenPoint: Point) {
        guard isEnabled, let offset = offsetForPoint(screenPoint) else { return }
        editorState.setCaret(offset, extendingSelection: false)
        commitChange()
    }

    func textPointerDragged(to screenPoint: Point) {
        guard isEnabled, let offset = offsetForPoint(screenPoint) else { return }
        editorState.setCaret(offset, extendingSelection: true)
        commitChange()
    }

    func textPointerUp(at screenPoint: Point) {}

    // MARK: Keyboard

    override func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled, press.phase == .down || press.phase == .repeat else { return .ignored }
        let mods = press.modifiers
        let shift = mods.contains(.shift)
        let cmd = mods.contains(.command)
        let ctrl = mods.contains(.control)
        let option = mods.contains(.option)
        let cmdOrCtrl = cmd || ctrl
        let wordMod = option || ctrl

        if cmdOrCtrl {
            switch press.key {
            case "a":
                editorState.selectAll()
                commitChange()
                return .handled
            case "z":
                if shift { editorState.redo() } else { editorState.undo() }
                commitChange()
                return .handled
            case "y":
                editorState.redo()
                commitChange()
                return .handled
            case .leftArrow:
                if cmd { editorState.moveToLineStart(extendingSelection: shift) }
                else { editorState.moveWordLeft(extendingSelection: shift) }
                commitChange()
                return .handled
            case .rightArrow:
                if cmd { editorState.moveToLineEnd(extendingSelection: shift) }
                else { editorState.moveWordRight(extendingSelection: shift) }
                commitChange()
                return .handled
            case .upArrow, .home:
                editorState.moveToDocumentStart(extendingSelection: shift)
                commitChange()
                return .handled
            case .downArrow, .end:
                editorState.moveToDocumentEnd(extendingSelection: shift)
                commitChange()
                return .handled
            case .delete:
                editorState.deleteBackward(byWord: true)
                commitChange()
                return .handled
            case .deleteForward:
                editorState.deleteForward(byWord: true)
                commitChange()
                return .handled
            default:
                return .ignored
            }
        }

        switch press.key {
        case .tab:
            return .ignored
        case .escape:
            if editorState.markedText != nil {
                editorState.cancelMarkedText()
                commitChange()
                return .handled
            }
            return .ignored
        case .return:
            editorState.insertText("\n")
            commitChange()
            return .handled
        case .leftArrow:
            if wordMod { editorState.moveWordLeft(extendingSelection: shift) }
            else { editorState.moveLeft(extendingSelection: shift) }
            commitChange()
            return .handled
        case .rightArrow:
            if wordMod { editorState.moveWordRight(extendingSelection: shift) }
            else { editorState.moveRight(extendingSelection: shift) }
            commitChange()
            return .handled
        case .upArrow:
            editorState.moveUp(extendingSelection: shift)
            commitChange()
            return .handled
        case .downArrow:
            editorState.moveDown(extendingSelection: shift)
            commitChange()
            return .handled
        case .home:
            editorState.moveToLineStart(extendingSelection: shift)
            commitChange()
            return .handled
        case .end:
            editorState.moveToLineEnd(extendingSelection: shift)
            commitChange()
            return .handled
        case .delete:
            editorState.deleteBackward(byWord: wordMod)
            commitChange()
            return .handled
        case .deleteForward:
            editorState.deleteForward(byWord: wordMod)
            commitChange()
            return .handled
        default:
            let chars = printableCharacters(from: press)
            guard !chars.isEmpty else { return .ignored }
            editorState.insertText(chars)
            commitChange()
            return .handled
        }
    }

    // MARK: Drawing

    override func draw(_ list: inout DisplayList) {
        guard let font, list.isVisible(frame) else { return }
        let lh = lineHeight(font)
        let lines = wrappedLines(forWidth: frame.width)
        let caretLineIdx = visualLineIndex(for: editorState.selection.caret, in: lines)
        let effectiveColor = isEnabled ? color : color.opacity(0.45)
        let originX = frame.minX + insetX
        let sel = editorState.selection.range
        let hasSelection = !editorState.selection.isCollapsed

        list.clipped(to: frame) { c in
            for (i, line) in lines.enumerated() {
                let lineTop = frame.minY + insetY + Double(i) * lh - scrollOffsetY
                if lineTop + lh <= frame.minY || lineTop >= frame.maxY { continue }
                let baseline = ((lineTop + (lh - font.lineHeight) / 2 + font.ascent) * scale).rounded() / scale

                if hasSelection {
                    let lo = max(sel.lowerBound, line.graphemeRange.lowerBound)
                    let hi = min(sel.upperBound, line.graphemeRange.upperBound)
                    let coversNewline = sel.upperBound > line.graphemeRange.upperBound
                        && sel.lowerBound <= line.graphemeRange.upperBound
                    if lo < hi || coversNewline {
                        let x0 = originX + line.caretPosition(at: lo)
                        let x1 = originX + line.caretPosition(at: max(lo, hi)) + (coversNewline ? 4 : 0)
                        c.fill(Rect(x: x0, y: lineTop, width: max(2, x1 - x0), height: lh),
                               effectiveColor.opacity(isFocused ? 0.28 : 0.14))
                    }
                }

                if !line.glyphs.isEmpty {
                    let tx = (originX * scale).rounded() / scale
                    c.drawGlyphs(line.glyphs, font: font.face, size: font.size, at: Point(x: tx, y: baseline),
                                 color: effectiveColor, options: options)
                }

                if let marked = editorState.markedText, !marked.range.isEmpty {
                    let mLo = max(marked.range.lowerBound, line.graphemeRange.lowerBound)
                    let mHi = min(marked.range.upperBound, line.graphemeRange.upperBound)
                    if mLo < mHi {
                        let mx0 = originX + line.caretPosition(at: mLo)
                        let mx1 = originX + line.caretPosition(at: mHi)
                        let underlineY = min(frame.maxY - 1, baseline + 2)
                        c.fill(Rect(x: mx0, y: underlineY, width: max(1, mx1 - mx0), height: 1),
                               effectiveColor.opacity(0.85))
                    }
                }

                if isFocused, isEnabled, i == caretLineIdx {
                    let cx = ((originX + line.caretPosition(at: editorState.selection.caret)) * scale).rounded() / scale
                    c.fill(Rect(x: cx, y: lineTop, width: caretWidth, height: lh), effectiveColor)
                }
            }
        }
    }
}
