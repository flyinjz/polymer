// TextField and TextEditor, as in SwiftUI: editable text bound to a String.
// A click puts the caret there (two select a word, three everything) and
// a drag selects; keys edit, move and select with the conventions of both
// macOS and Windows (each combination does the same on every OS); the
// clipboard is `ViewTree.clipboard`; undo and redo are per field. Input
// methods compose through `ViewTree.setMarkedText` and friends. The look
// (caret, selection, placeholder) is a placeholder for PolymerDesign.
import PolymerBase
import PolymerText
import PolymerRender

/// Where cut, copied and pasted text goes. A window installs the system's;
/// headless trees use a `MemoryClipboard`, so checks never touch the real one.
public protocol Clipboard: AnyObject {
    var string: String? { get set }
}

/// A clipboard that lives in memory.
public final class MemoryClipboard: Clipboard {
    public var string: String?
    public init(_ string: String? = nil) { self.string = string }
}

/// One line of editable text: edits a `String` binding. `title` is shown,
/// dimmed, while it is empty. Return runs the `.onSubmit` action.
public struct TextField: View, PrimitiveView {
    let title: String
    let text: Binding<String>
    public init(_ title: String, text: Binding<String>) { self.title = title; self.text = text }
    public var body: Never { fatalError("TextField is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TextInputNode).flatMap { $0.multiline ? nil : $0 } ?? TextInputNode(multiline: false)
        n.configure(title: title, text: text, c)
        return n
    }
}

/// Several lines of editable text, wrapped to its width: edits a `String` binding.
/// Takes the space it is offered; scrolls to keep the caret in view.
public struct TextEditor: View, PrimitiveView {
    let text: Binding<String>
    public init(text: Binding<String>) { self.text = text }
    public var body: Never { fatalError("TextEditor is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TextInputNode).flatMap { $0.multiline ? $0 : nil } ?? TextInputNode(multiline: true)
        n.configure(title: "", text: text, c)
        return n
    }
}

extension View {
    /// What Return does in a `TextField` inside this view.
    public func onSubmit(_ action: @escaping @MainActor () -> Void) -> some View {
        environment(\.submitAction, SubmitAction(run: action))
    }
}

struct SubmitAction { let run: @MainActor () -> Void }
struct SubmitActionKey: EnvironmentKey { static var defaultValue: SubmitAction? { nil } }
extension EnvironmentValues {
    var submitAction: SubmitAction? {
        get { self[SubmitActionKey.self] }
        set { self[SubmitActionKey.self] = newValue }
    }
}

/// How the views a text field draws look (placeholders for design tokens).
enum TextInputLook {
    /// The placeholder: the text colour at this opacity.
    static let placeholderOpacity = 0.4
    /// The selection: the text colour at this opacity, behind the text.
    static let selectionOpacity = 0.25
    /// The caret's width in points.
    static let caretWidth = 1.0
}

/// A line of laid-out editable text: the characters it shows and where the caret can go.
struct EditorLine {
    var range: Range<Int>
    var glyphs: [PositionedGlyph]
    /// The caret's x (from the line's start) before each character of `range`, and after the last.
    var carets: [Double]
}

/// Text input: what a TextField or TextEditor is in the tree.
final class TextInputNode: Node {
    let multiline: Bool
    init(multiline: Bool) { self.multiline = multiline; super.init() }

    var title = ""
    var binding: Binding<String>?
    var font: Font?
    var color: Color = .white
    var options: TextRenderingOptions = .standard
    var isEnabled = true
    var submit: SubmitAction?
    private(set) var editing = TextEditing()
    /// How far the content is scrolled (x for a field, y for an editor), in points.
    private(set) var scrollOffset = 0.0
    private var lines: [EditorLine] = []
    private var linesWidth: Double? = -1
    /// Where the pointer went down, for dragging a selection.
    private var dragAnchor: Range<Int>?

    func configure(title: String, text: Binding<String>, _ c: ResolveContext) {
        self.title = title
        binding = text
        let e = c.environment
        if font != e.font { font = e.font; linesWidth = -1 }
        color = e.foregroundColor
        options = e.textRendering
        isEnabled = e.isEnabled
        submit = e.submitAction
        // Read now, while resolving, not in the body: reported to the enclosing view so a change to it updates the field.
        let value = c.host?.track { text.wrappedValue } ?? text.wrappedValue
        if value != editing.text { editing.setText(multiline ? value : value.replacingNewlines); linesWidth = -1 }
        if font == nil { Logger("PolymerUI").warning("\(multiline ? "TextEditor" : "TextField(\"\(title)\")") has no font; set one with .font(Font(face, size:)) on it or an ancestor") }
    }

    override var role: String { multiline ? "TextEditor" : "TextField" }
    override var detail: String {
        var d = editing.count == 0 && !title.isEmpty ? "placeholder \"\(title)\"" : "\"\(editing.text.escapedNewlines)\""
        let s = editing.selection
        if tree?.focused === self { d += s.isEmpty ? " caret \(editing.head)" : " selection \(s.lowerBound)..\(s.upperBound)" }
        if let m = editing.marked { d += " marked \(m.lowerBound)..\(m.upperBound)" }
        if !isEnabled { d += " disabled" }
        return d
    }
    override var acceptsFocus: Bool { isEnabled }
    override var focusesOnClick: Bool { isEnabled }
    override var isHitTarget: Bool { true }
    override var clipsContent: Bool { true }

    // MARK: Layout

    private var lineHeight: Double {
        guard let font else { return 0 }
        return (font.lineHeight * scale).rounded(.up) / scale
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        if multiline { return p.replacingUnspecified(Size(width: 10, height: 10)) }
        guard let font else { return .zero }
        // A field takes the width offered; offered none, its text's (or its placeholder's).
        let shown = editing.count == 0 ? title : editing.text
        let w = TextLayout.line(shown, font: font.face, pixelSize: font.size).reduce(0) { max($0, $1.x + $1.advance) }
        return Size(width: p.width ?? (w * scale).rounded(.up) / scale + TextInputLook.caretWidth, height: lineHeight)
    }

    override func placeChildren(in r: Rect) {
        linesWidth = -1
        keepCaretInView()
    }

    /// The lines of the text for the current width (kept until the text, font or width changes).
    private func laidOut() -> [EditorLine] {
        let width: Double? = multiline ? max(1, layoutFrame.width) : nil
        if linesWidth == width { return lines }
        lines = TextInputNode.layout(editing.chars, font: font, width: width)
        linesWidth = width
        return lines
    }

    /// Lays out `chars`: paragraphs split at line breaks, each wrapped to `width` (nil: one line each).
    static func layout(_ chars: [Character], font: Font?, width: Double?) -> [EditorLine] {
        guard let font else { return [EditorLine(range: 0..<0, glyphs: [], carets: [0])] }
        var out: [EditorLine] = []
        var start = 0
        while true {
            var end = start
            while end < chars.count, chars[end] != "\n", chars[end] != "\r\n" { end += 1 }
            out += paragraph(Array(chars[start..<end]), offset: start, font: font, width: width)
            if end >= chars.count { break }
            start = end + 1
        }
        return out
    }

    private static func paragraph(_ chars: [Character], offset: Int, font: Font, width: Double?) -> [EditorLine] {
        guard !chars.isEmpty else { return [EditorLine(range: offset..<offset, glyphs: [], carets: [0])] }
        let text = String(chars)
        // Scalar index where each character starts, and one past the end.
        var scalarStart: [Int] = []
        scalarStart.reserveCapacity(chars.count + 1)
        var s = 0
        for c in chars { scalarStart.append(s); s += c.unicodeScalars.count }
        scalarStart.append(s)
        func charIndex(ofScalar k: Int) -> Int {
            var lo = 0, hi = chars.count
            while lo < hi { let m = (lo + hi + 1) / 2; if scalarStart[m] <= k { lo = m } else { hi = m - 1 } }
            return lo
        }
        // The paragraph's glyphs keep their clusters (scalar indices); lines are runs of them.
        let all = TextLayout.line(text, font: font.face, pixelSize: font.size)
        let runs = width.map { wrap(all, Array(text.unicodeScalars), maxWidth: $0) } ?? [0..<all.count]
        let laid = runs.map { Array(all[$0]) }
        var out: [EditorLine] = []
        for (i, glyphs) in laid.enumerated() {
            let lo = i == 0 ? 0 : charIndex(ofScalar: glyphs.first?.cluster ?? scalarStart[chars.count])
            let hi = i + 1 < laid.count ? charIndex(ofScalar: laid[i + 1].first?.cluster ?? scalarStart[chars.count]) : chars.count
            // A glyph stands for the characters from its cluster to the next glyph's; a ligature's carets split it evenly.
            var carets = [Double](repeating: 0, count: hi - lo + 1)
            let x0 = glyphs.first?.x ?? 0
            var g = 0
            for ci in lo..<hi {
                let sc = scalarStart[ci]
                while g + 1 < glyphs.count, glyphs[g + 1].cluster <= sc { g += 1 }
                guard g < glyphs.count else { carets[ci - lo] = carets[max(0, ci - lo - 1)]; continue }
                let c0 = glyphs[g].cluster
                var j = g + 1
                while j < glyphs.count, glyphs[j].cluster == c0 { j += 1 }
                let c1 = j < glyphs.count ? glyphs[j].cluster : scalarStart[hi]
                let x1 = j < glyphs.count ? glyphs[j].x : (glyphs.last.map { $0.x + $0.advance } ?? 0)
                let f = c1 > c0 ? Double(sc - c0) / Double(c1 - c0) : 0
                carets[ci - lo] = glyphs[g].x - x0 + (x1 - glyphs[g].x) * f
            }
            carets[hi - lo] = (glyphs.last.map { $0.x + $0.advance } ?? x0) - x0
            out.append(EditorLine(range: (offset + lo)..<(offset + hi), glyphs: glyphs, carets: carets))
        }
        return out
    }

    /// The line the caret at `offset` is on (at a wrap, the start of the next line).
    private func lineIndex(of offset: Int) -> Int {
        let ls = laidOut()
        for (i, l) in ls.enumerated() {
            if offset < l.range.lowerBound { return max(0, i - 1) }
            if offset < l.range.upperBound { return i }
            // At the end of the line: it is this line's unless the next one starts right here (a wrap).
            if offset == l.range.upperBound, i + 1 == ls.count || ls[i + 1].range.lowerBound > offset { return i }
        }
        return max(0, ls.count - 1)
    }

    /// The caret's position for `offset`, relative to the content's top-leading corner (unscrolled).
    private func caretPoint(_ offset: Int) -> Point {
        let ls = laidOut()
        let i = lineIndex(of: offset)
        let l = ls[i]
        let k = min(max(offset - l.range.lowerBound, 0), l.carets.count - 1)
        return Point(x: l.carets[k], y: Double(i) * lineHeight)
    }

    /// The character offset nearest to `p` (screen points).
    func offset(at p: Point) -> Int {
        let ls = laidOut()
        let o = screenFrame.origin
        var x = p.x - o.x, y = p.y - o.y
        if multiline { y += scrollOffset } else { x += scrollOffset }
        let i = min(max(Int((y / max(lineHeight, 1)).rounded(.down)), 0), ls.count - 1)
        let l = ls[i]
        var best = 0
        for k in l.carets.indices where abs(l.carets[k] - x) < abs(l.carets[best] - x) { best = k }
        // The end of a wrapped line is the start of the next: stay on this line.
        if i + 1 < ls.count, best == l.carets.count - 1, l.range.upperBound == ls[i + 1].range.lowerBound, best > 0 { best -= 1 }
        return l.range.lowerBound + best
    }

    /// Scrolls so the caret is in view.
    private func keepCaretInView() {
        guard font != nil else { return }
        let c = caretPoint(editing.head)
        let f = layoutFrame
        if multiline {
            let lh = lineHeight
            if c.y < scrollOffset { scrollOffset = c.y }
            if c.y + lh > scrollOffset + f.height { scrollOffset = c.y + lh - f.height }
            let content = Double(laidOut().count) * lh
            scrollOffset = max(0, min(scrollOffset, max(0, content - f.height)))
        } else {
            let room = max(0, f.width - TextInputLook.caretWidth)
            if c.x < scrollOffset { scrollOffset = c.x }
            if c.x > scrollOffset + room { scrollOffset = c.x - room }
            let w = laidOut().first?.carets.last ?? 0
            scrollOffset = max(0, min(scrollOffset, max(0, w - room)))
        }
        scrollOffset = (scrollOffset * scale).rounded() / scale
    }

    // MARK: Drawing

    override func drawContent(_ list: inout DisplayList) {
        guard let font, list.isVisible(frame) else { return }
        let f = frame
        let focused = tree?.focused === self
        list.clipped(to: f) { list in
            let lh = lineHeight
            let shift = multiline ? Point(x: f.minX, y: f.minY - scrollOffset) : Point(x: f.minX - scrollOffset, y: f.minY)
            if editing.count == 0 {
                if !title.isEmpty {
                    let glyphs = TextLayout.line(title, font: font.face, pixelSize: font.size)
                    let baseline = baselineY(row: 0, top: shift.y, font: font)
                    list.drawGlyphs(glyphs, font: font.face, size: font.size, at: Point(x: snap(shift.x), y: baseline),
                                    color: color.opacity(TextInputLook.placeholderOpacity), options: options)
                }
            } else {
                let ls = laidOut()
                let sel = editing.selection
                for (i, l) in ls.enumerated() {
                    let top = shift.y + Double(i) * lh
                    guard top + lh > f.minY, top < f.maxY else { continue }
                    // Selection behind the text.
                    if focused, !sel.isEmpty {
                        let a = max(sel.lowerBound, l.range.lowerBound), b = min(sel.upperBound, l.range.upperBound)
                        // A selected line break (the next line starts after one) shows as a little room after the line.
                        let breakSelected = i + 1 < ls.count && ls[i + 1].range.lowerBound > l.range.upperBound
                            && sel.lowerBound <= l.range.upperBound && sel.upperBound > l.range.upperBound
                        if a < b || breakSelected {
                            let x0 = l.carets[a - l.range.lowerBound]
                            let x1 = l.carets[b - l.range.lowerBound] + (breakSelected ? font.size * 0.3 : 0)
                            list.fill(Rect(x: shift.x + x0, y: top, width: max(0, x1 - x0), height: lh),
                                      color.opacity(TextInputLook.selectionOpacity))
                        }
                    }
                    let baseline = baselineY(row: i, top: shift.y, font: font)
                    list.drawGlyphs(l.glyphs, font: font.face, size: font.size,
                                    at: Point(x: snap(shift.x - (l.glyphs.first?.x ?? 0)), y: baseline), color: color, options: options)
                    // Marked text is underlined.
                    if let m = editing.marked, m.overlaps(l.range) {
                        let a = max(m.lowerBound, l.range.lowerBound) - l.range.lowerBound
                        let b = min(m.upperBound, l.range.upperBound) - l.range.lowerBound
                        list.fill(Rect(x: shift.x + l.carets[a], y: baseline + 2, width: l.carets[b] - l.carets[a], height: 1 / scale), color)
                    }
                }
            }
            if focused, editing.selection.isEmpty {
                let c = caretPoint(editing.head)
                list.fill(Rect(x: snap(shift.x + c.x), y: shift.y + c.y, width: TextInputLook.caretWidth, height: lh), color)
            }
        }
    }

    private func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }

    private func baselineY(row: Int, top: Double, font: Font) -> Double {
        let lh = lineHeight
        return ((top + Double(row) * lh + (lh - font.lineHeight) / 2 + font.ascent) * scale).rounded() / scale
    }

    // MARK: Editing

    /// After an edit: write the binding, scroll to the caret, redraw.
    private func edited(textChanged: Bool) {
        if textChanged {
            linesWidth = -1
            let t = editing.text
            if let b = binding, b.wrappedValue != t { b.wrappedValue = t }
            if !multiline { invalidateLayoutUpward() }
        }
        keepCaretInView()
    }

    private func edit(_ body: (inout TextEditing) -> Void) {
        let before = editing.text
        body(&editing)
        edited(textChanged: editing.text != before)
    }

    func insert(_ s: String) {
        guard isEnabled else { return }
        edit { $0.insert(multiline ? s : s.replacingNewlines) }
    }

    override func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled, press.phase != .up else { return .ignored }
        let m = press.modifiers
        let shift = m.contains(.shift)
        let word = m.contains(.option) || m.contains(.control)   // macOS option, Windows Ctrl
        let line = m.contains(.command)
        let shortcut = m.contains(.command) || m.contains(.control)
        let e = editing
        switch press.key {
        case .leftArrow:
            let target = line ? lineStart(e.head) : word ? e.wordStart(before: e.head)
                : (!shift && !e.selection.isEmpty ? e.selection.lowerBound : e.head - 1)
            edit { $0.select(to: target, extend: shift) }
        case .rightArrow:
            let target = line ? lineEnd(e.head) : word ? e.wordEnd(after: e.head)
                : (!shift && !e.selection.isEmpty ? e.selection.upperBound : e.head + 1)
            edit { $0.select(to: target, extend: shift) }
        case .home: edit { $0.select(to: m.contains(.control) ? 0 : lineStart(e.head), extend: shift) }
        case .end: edit { $0.select(to: m.contains(.control) ? e.count : lineEnd(e.head), extend: shift) }
        case .upArrow: edit { $0.select(to: line || !multiline ? 0 : verticalMove(e.head, -1), extend: shift) }
        case .downArrow: edit { $0.select(to: line || !multiline ? e.count : verticalMove(e.head, 1), extend: shift) }
        case .delete:
            edit { $0.delete(to: line ? lineStart(e.head) : word ? e.wordStart(before: e.head) : e.head - 1) }
        case .deleteForward:
            edit { $0.delete(to: word ? e.wordEnd(after: e.head) : e.head + 1) }
        case .return:
            if multiline { edit { $0.insert("\n") } } else if let s = submit { s.run() } else { return .ignored }
        case .tab, .escape:
            return .ignored
        default:
            if shortcut, !(m.contains(.option)) {
                switch press.key.character {
                case "a": edit { $0.selectAll() }
                case "c": copy()
                case "x": if copy() { edit { $0.delete(to: $0.head) } }
                case "v": if let s = tree?.clipboard?.string { insert(s) }
                case "z": edit { if shift { $0.redo() } else { $0.undo() } }
                case "y" where m.contains(.control): edit { $0.redo() }
                default: return .ignored
                }
                return .handled
            }
            guard let c = press.characters.first, press.characters.isPrintable else { return .ignored }
            _ = c
            insert(press.characters)
        }
        return .handled
    }

    @discardableResult
    private func copy() -> Bool {
        guard !editing.selection.isEmpty, let cb = tree?.clipboard else { return false }
        cb.string = editing.selectedText
        return true
    }

    private func lineStart(_ offset: Int) -> Int { laidOut()[lineIndex(of: offset)].range.lowerBound }
    private func lineEnd(_ offset: Int) -> Int { laidOut()[lineIndex(of: offset)].range.upperBound }

    /// The offset `rows` lines up or down at the same x (the start or end of the text past the first or last line).
    private func verticalMove(_ offset: Int, _ rows: Int) -> Int {
        let ls = laidOut()
        let i = lineIndex(of: offset) + rows
        if i < 0 { return 0 }
        if i >= ls.count { return editing.count }
        let x = caretPoint(offset).x
        let l = ls[i]
        var best = 0
        for k in l.carets.indices where abs(l.carets[k] - x) < abs(l.carets[best] - x) { best = k }
        if i + 1 < ls.count, best == l.carets.count - 1, best > 0, l.range.upperBound == ls[i + 1].range.lowerBound { best -= 1 }
        return l.range.lowerBound + best
    }

    // MARK: Pointer

    func pointerDown(at p: Point, clickCount: Int) {
        guard isEnabled else { return }
        let o = offset(at: p)
        switch clickCount {
        case 1: dragAnchor = o..<o; edit { $0.select(to: o) }
        case 2: let w = editing.wordRange(at: o); dragAnchor = w; edit { $0.select(w) }
        default: dragAnchor = 0..<editing.count; edit { $0.selectAll() }
        }
    }

    func pointerDragged(to p: Point) {
        guard let a = dragAnchor else { return }
        let o = offset(at: p)
        edit { e in
            if o < a.lowerBound { e.select(anchor: a.upperBound, head: o) } else { e.select(anchor: a.lowerBound, head: max(o, a.upperBound)) }
        }
    }

    func pointerUp() { dragAnchor = nil }

    // MARK: Input methods

    func setMarked(_ s: String, selected: Range<Int>) {
        guard isEnabled else { return }
        edit { $0.setMarked(multiline ? s : s.replacingNewlines, selected: selected) }
    }
    func unmark() { edit { $0.unmark() } }
    var markedRange: Range<Int>? { editing.marked }
    var selectedRange: Range<Int> { editing.selection }

    /// The screen rectangle of the first line of `range` (an input method puts its candidate window there).
    func firstRect(for range: Range<Int>) -> Rect {
        let a = caretPoint(range.lowerBound)
        let i = lineIndex(of: range.lowerBound)
        let l = laidOut()[i]
        let b = min(range.upperBound, l.range.upperBound)
        let x1 = caretPoint(b).y == a.y ? caretPoint(b).x : (l.carets.last ?? a.x)
        let o = screenFrame.origin
        let shift = multiline ? Point(x: o.x, y: o.y - scrollOffset) : Point(x: o.x - scrollOffset, y: o.y)
        return Rect(x: shift.x + a.x, y: shift.y + a.y, width: max(0, x1 - a.x), height: lineHeight)
    }

    override func unmount() {
        dragAnchor = nil
        super.unmount()
    }
}

extension String {
    var replacingNewlines: String { String(map { $0 == "\n" || $0 == "\r\n" ? " " : $0 }) }
    var escapedNewlines: String {
        var s = ""
        for c in self { if c == "\n" { s += "\\n" } else { s.append(c) } }
        return s
    }
    /// True when typing these characters should insert them (not a control key or a function key).
    var isPrintable: Bool {
        guard !isEmpty else { return false }
        for s in unicodeScalars {
            if s.value < 0x20 || s.value == 0x7F { return false }
            if (0xF700...0xF8FF).contains(s.value) { return false }   // arrow and function keys
        }
        return true
    }
}


extension TextInputNode {
    /// Where a paragraph's glyphs break into lines of at most `maxWidth`:
    /// after a run of spaces (the spaces stay on the line, past its edge) or
    /// a hyphen, else between characters for a word too long for a line. The
    /// same rule as `Text`'s wrapping, kept with the clusters a caret needs.
    static func wrap(_ g: [PositionedGlyph], _ text: [Unicode.Scalar], maxWidth: Double) -> [Range<Int>] {
        func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\u{200B}" }
        guard !g.isEmpty else { return [0..<0] }
        var out: [Range<Int>] = []
        var s = 0
        repeat {
            let x0 = g[s].x
            var next = g.count
            var breakAt: Int?
            var i = s
            while i < g.count {
                if isSpace(text[g[i].cluster]) {
                    var j = i
                    while j < g.count, isSpace(text[g[j].cluster]) { j += 1 }
                    if i > s { breakAt = j }
                    i = j
                    continue
                }
                if g[i].x + g[i].advance - x0 > maxWidth + 1e-9, i > s { next = breakAt ?? i; break }
                if text[g[i].cluster] == "-", i + 1 < g.count, !isSpace(text[g[i + 1].cluster]) { breakAt = i + 1 }
                i += 1
            }
            out.append(s..<next)
            s = next
        } while s < g.count
        return out
    }
}
