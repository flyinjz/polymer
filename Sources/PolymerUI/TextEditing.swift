// The editing model behind TextField and TextEditor: the characters, the
// selection (an anchor and a moving end), the text an input method is
// composing (marked text), and undo. Positions are character offsets
// (grapheme clusters, Swift's `Character`); the platform layer converts to
// UTF-16 where an OS wants it. Pure value code, no layout: moving up and
// down lines is done by the views, which know where the lines break.
import PolymerBase

struct TextEditing: Equatable {
    private(set) var chars: [Character]
    /// Where the selection started (it stays put while the selection is extended).
    private(set) var anchor: Int
    /// The moving end of the selection: where the caret is.
    private(set) var head: Int
    /// The text an input method is composing, still to be confirmed; nil when none.
    private(set) var marked: Range<Int>?

    private struct Snapshot: Equatable { var chars: [Character]; var anchor: Int; var head: Int }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// What the last edit was, so a run of typing (or of deleting) undoes as one step.
    private enum EditKind: Equatable { case none, typing, deleting }
    private var lastEdit = EditKind.none
    /// Most undo steps kept.
    static let undoLimit = 200

    init(_ text: String = "") {
        chars = Array(text)
        anchor = chars.count
        head = chars.count
    }

    var text: String { String(chars) }
    var count: Int { chars.count }
    var selection: Range<Int> { min(anchor, head)..<max(anchor, head) }
    var selectedText: String { String(chars[selection]) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Replacing the text

    /// The text changed from outside (the binding): keep the caret where it can be, drop composition and undo.
    mutating func setText(_ s: String) {
        let new = Array(s)
        guard new != chars else { return }
        chars = new
        anchor = min(anchor, chars.count); head = min(head, chars.count)
        marked = nil
        undoStack.removeAll(); redoStack.removeAll(); lastEdit = .none
    }

    // MARK: Selection

    /// Puts the caret at `offset`, or with `extend` moves the selection's moving end there.
    mutating func select(to offset: Int, extend: Bool = false) {
        let o = min(max(offset, 0), chars.count)
        head = o
        if !extend { anchor = o }
        lastEdit = .none
    }

    mutating func select(_ range: Range<Int>) { select(anchor: range.lowerBound, head: range.upperBound) }

    /// Selects from `anchor` (which stays) to `head` (where the caret is); either way round.
    mutating func select(anchor a: Int, head h: Int) {
        anchor = min(max(a, 0), chars.count)
        head = min(max(h, 0), chars.count)
        lastEdit = .none
    }

    mutating func selectAll() { select(0..<chars.count) }

    /// The word (or run of spaces or punctuation) around `offset`.
    func wordRange(at offset: Int) -> Range<Int> {
        guard !chars.isEmpty else { return 0..<0 }
        let o = min(max(offset, 0), chars.count - 1)
        let kind = TextEditing.kind(chars[o])
        var lo = o, hi = o + 1
        while lo > 0, TextEditing.kind(chars[lo - 1]) == kind { lo -= 1 }
        while hi < chars.count, TextEditing.kind(chars[hi]) == kind { hi += 1 }
        return lo..<hi
    }

    /// What a word move treats a character as.
    private enum Kind { case word, space, newline, other }
    private static func kind(_ c: Character) -> Kind {
        if c == "\n" || c == "\r\n" { return .newline }
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .other
    }

    /// The start of the word before `offset` (skipping anything that is not a word first).
    func wordStart(before offset: Int) -> Int {
        var i = min(offset, chars.count)
        while i > 0, TextEditing.kind(chars[i - 1]) != .word { i -= 1 }
        while i > 0, TextEditing.kind(chars[i - 1]) == .word { i -= 1 }
        return i
    }

    /// The end of the word after `offset`.
    func wordEnd(after offset: Int) -> Int {
        var i = max(offset, 0)
        while i < chars.count, TextEditing.kind(chars[i]) != .word { i += 1 }
        while i < chars.count, TextEditing.kind(chars[i]) == .word { i += 1 }
        return i
    }

    /// The start and end of the paragraph (between line breaks) around `offset`.
    func paragraphStart(_ offset: Int) -> Int {
        var i = min(offset, chars.count)
        while i > 0, chars[i - 1] != "\n", chars[i - 1] != "\r\n" { i -= 1 }
        return i
    }
    func paragraphEnd(_ offset: Int) -> Int {
        var i = max(offset, 0)
        while i < chars.count, chars[i] != "\n", chars[i] != "\r\n" { i += 1 }
        return i
    }

    // MARK: Editing

    /// Replaces the selection (or the marked text) with `s`: what typing and pasting do.
    mutating func insert(_ s: String) {
        let range = marked ?? selection
        let typing = s.count == 1 && marked == nil
        remember(typing ? .typing : .none)
        replace(range, with: Array(s))
        marked = nil
        lastEdit = typing ? .typing : .none
    }

    /// Deletes the selection, or (when it is empty) from the caret to `offset`.
    mutating func delete(to offset: Int) {
        marked = nil
        var range = selection
        if range.isEmpty {
            let o = min(max(offset, 0), chars.count)
            range = min(o, head)..<max(o, head)
        }
        guard !range.isEmpty else { return }
        remember(.deleting)
        replace(range, with: [])
        lastEdit = .deleting
    }

    private mutating func replace(_ range: Range<Int>, with new: [Character]) {
        chars.replaceSubrange(range, with: new)
        let end = range.lowerBound + new.count
        anchor = end; head = end
    }

    /// Saves the state before an edit for undo, unless it continues a run of the same kind.
    private mutating func remember(_ kind: EditKind) {
        redoStack.removeAll()
        if kind != .none, kind == lastEdit, !undoStack.isEmpty { return }
        undoStack.append(Snapshot(chars: chars, anchor: anchor, head: head))
        if undoStack.count > TextEditing.undoLimit { undoStack.removeFirst() }
    }

    mutating func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(chars: chars, anchor: anchor, head: head))
        chars = s.chars; anchor = s.anchor; head = s.head
        marked = nil; lastEdit = .none
    }

    mutating func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(chars: chars, anchor: anchor, head: head))
        chars = s.chars; anchor = s.anchor; head = s.head
        marked = nil; lastEdit = .none
    }

    // MARK: Input methods

    /// An input method's text in progress replaces the marked text (or the
    /// selection); `selected` is the caret or selection inside it.
    mutating func setMarked(_ s: String, selected: Range<Int>) {
        let range = marked ?? selection
        if marked == nil { remember(.none) }
        let new = Array(s)
        chars.replaceSubrange(range, with: new)
        let start = range.lowerBound
        marked = new.isEmpty ? nil : start..<(start + new.count)
        anchor = start + min(max(selected.lowerBound, 0), new.count)
        head = start + min(max(selected.upperBound, 0), new.count)
        lastEdit = .none
    }

    /// The input method confirmed its text as it is.
    mutating func unmark() {
        guard let m = marked else { return }
        marked = nil
        anchor = m.upperBound; head = m.upperBound
    }
}
