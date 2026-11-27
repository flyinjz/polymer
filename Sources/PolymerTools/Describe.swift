// `polymer describe` and the JSON forms of `polymer tree`: a screen in plain
// words, and the element and accessibility trees as data.
import PolymerBase
import PolymerUI
import PolymerDesign

enum Describe {
    // MARK: Plain words

    /// What `--customize` changed, in one line, for `polymer describe --customize`
    /// and `polymer render --customize`: "Customized 3 elements: play hidden, ...".
    static func customizeNote(_ model: CustomizeModel) -> String {
        guard !model.elements.isEmpty else { return "Customized: the file changes nothing (every element is as its app draws it)." }
        var parts: [String] = []
        for path in model.elements.keys.sorted() {
            let e = model[path]
            var what: [String] = []
            if e.hidden { what.append("hidden") }
            if e.scale != 1 { what.append("scale \(number(e.scale))") }
            if let s = e.style { what.append("style \"\(s)\"") }
            parts.append("\(path) \(what.joined(separator: ", "))")
        }
        return "Customized \(model.elements.count) \(model.elements.count == 1 ? "element" : "elements"): \(parts.joined(separator: "; "))."
    }

    /// What the screen holds, in plain sentences, from its accessibility tree.
    static func plain(_ screen: String, _ root: AccessibilityElement) -> String {
        var out = "Screen \"\(screen)\", \(number(root.frame.width)) by \(number(root.frame.height)) points.\n\n"
        var lines: [String] = []
        for e in root.children { describe(e, depth: 0, into: &lines) }
        if lines.isEmpty {
            out += "It shows nothing a screen reader can see.\n"
        } else {
            out += lines.joined(separator: "\n") + "\n"
        }
        out += "\n"
        let counts = roleCounts(root)
        if !counts.isEmpty {
            out += "In all: " + counts.map { plural($0.count, $0.role) }.joined(separator: ", ") + ".\n"
        }
        if let f = focused(root) {
            out += "Focus: \(phrase(f)).\n"
        } else {
            out += "Focus: nothing has focus. --key tab moves it to the first focusable view.\n"
        }
        return out
    }

    private static func describe(_ e: AccessibilityElement, depth: Int, into lines: inout [String]) {
        // A group with no label of its own adds nothing to say: its children stand at its level.
        if e.role == .group, e.label.isEmpty {
            for c in e.children { describe(c, depth: depth, into: &lines) }
            return
        }
        var line = String(repeating: "  ", count: depth) + "- " + phrase(e)
        if !e.children.isEmpty { line += ", with:" }
        lines.append(line)
        for c in e.children { describe(c, depth: depth + 1, into: &lines) }
    }

    /// One element in words: `Button "Add"`, `Text field "Name", containing "Ada", focused`.
    static func phrase(_ e: AccessibilityElement) -> String {
        let quoted = e.label.isEmpty ? "" : " \"\(e.label)\""
        var s: String
        switch e.role {
        case .staticText: s = (e.traits.contains(.isHeader) ? "Heading" : "Text") + quoted
        case .button: s = (e.traits.contains(.isLink) ? "Link" : "Button") + quoted
        case .image: s = e.label.isEmpty ? "Image with no label" : "Image" + quoted
        case .textField:
            s = "Text field" + quoted
            if let v = e.value { s += v.isEmpty ? ", empty" : ", containing \"\(v)\"" }
        case .scrollArea: s = "Scrolling area" + quoted
        case .group: s = "Group" + quoted
        case .focusable: s = "Focusable view" + quoted
        case .menu: s = "Open menu" + quoted
        case .popover: s = "Open popover" + quoted
        case .dialog: s = "Open sheet" + quoted
        }
        if e.role != .textField, let v = e.value { s += ", value \"\(v)\"" }
        if let h = e.hint { s += ", hint \"\(h)\"" }
        if e.traits.contains(.isSelected) { s += ", selected" }
        if !e.isEnabled { s += ", disabled" }
        if e.isFocused { s += ", focused" }
        return s
    }

    /// Words for each role, singular and plural, in the order counts are given.
    private static let roleWords: [(AccessibilityRole, String, String)] = [
        (.staticText, "text", "texts"), (.button, "button", "buttons"), (.textField, "text field", "text fields"),
        (.image, "image", "images"), (.scrollArea, "scrolling area", "scrolling areas"),
        (.focusable, "focusable view", "focusable views"), (.menu, "open menu", "open menus"),
        (.popover, "open popover", "open popovers"), (.dialog, "open sheet", "open sheets"),
    ]

    private static func plural(_ n: Int, _ role: AccessibilityRole) -> String {
        guard let w = roleWords.first(where: { $0.0 == role }) else { return "\(n) \(role.rawValue)" }
        return "\(n) \(n == 1 ? w.1 : w.2)"
    }

    /// How many elements of each role (groups left out), in `roleWords` order.
    static func roleCounts(_ root: AccessibilityElement) -> [(role: AccessibilityRole, count: Int)] {
        var counts: [AccessibilityRole: Int] = [:]
        func walk(_ e: AccessibilityElement) {
            if e.role != .group { counts[e.role, default: 0] += 1 }
            for c in e.children { walk(c) }
        }
        for c in root.children { walk(c) }
        return roleWords.compactMap { w in counts[w.0].map { (w.0, $0) } }
    }

    static func focused(_ e: AccessibilityElement) -> AccessibilityElement? {
        if e.isFocused { return e }
        for c in e.children { if let f = focused(c) { return f } }
        return nil
    }

    private static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    // MARK: JSON

    /// `polymer describe --json`: the screen, its size, its elements, the counts and the focus.
    static func screenJSON(_ screen: String, _ root: AccessibilityElement) -> JSON {
        var counts: [String: JSON] = [:]
        for c in roleCounts(root) { counts[c.role.rawValue] = .number(Double(c.count)) }
        return [
            "screen": .string(screen),
            "width": .number(root.frame.width),
            "height": .number(root.frame.height),
            "elements": .array(root.children.map { Describe.json($0) }),
            "counts": .object(counts),
            "focused": focused(root).map { JSON.string(phrase($0)) } ?? JSON.null,
            "text": .string(plain(screen, root)),
        ]
    }

    /// Trait names, as `polymer tree --a11y` prints them.
    private static let traitNames: [(AccessibilityTraits, String)] = [
        (.isButton, "button"), (.isHeader, "header"), (.isSelected, "selected"),
        (.isImage, "image"), (.isStaticText, "text"), (.isLink, "link"),
    ]

    /// An accessibility element and its children as JSON.
    static func json(_ e: AccessibilityElement) -> JSON {
        [
            "role": .string(e.role.rawValue),
            "label": .string(e.label),
            "value": e.value.map { JSON.string($0) } ?? JSON.null,
            "hint": e.hint.map { JSON.string($0) } ?? JSON.null,
            "traits": .array(traitNames.filter { e.traits.contains($0.0) }.map { JSON.string($0.1) }),
            "frame": frameJSON(e.frame.minX, e.frame.minY, e.frame.width, e.frame.height),
            "enabled": .bool(e.isEnabled),
            "focused": .bool(e.isFocused),
            "children": .array(e.children.map { Describe.json($0) }),
        ]
    }

    private static func frameJSON(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSON {
        ["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)]
    }

    /// `polymer tree --json`: the element tree text (`ViewTree.elementTree`) as nested objects:
    /// role, frame, detail, focused, leaving, children. A line that is not an element (the
    /// second line of a text with a line break in it) is added, as printed, to the detail
    /// before it. Details are printed raw, so such a line starts at column 0 and the element's
    /// "focused" and "leaving" come at the end of its last line; they are read after joining.
    static func elementTreeJSON(_ text: String) -> JSON {
        var items: [ElementLine] = []
        // `isNewline` also splits "\r\n", which Swift holds as one Character.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        if lines.last?.isEmpty == true { lines.removeLast() }  // the final line end
        for raw in lines {
            // An empty line can only be a blank line inside a text, so it is kept.
            let line = String(raw)
            if let item = parseElementLine(line) {
                items.append(item)
            } else if !items.isEmpty {
                items[items.count - 1].detail += "\n" + line
            }
        }
        for i in items.indices { items[i].takeFlags() }
        var index = 0
        return .array(buildElements(items, &index, depth: 0))
    }

    /// One line of the element tree.
    struct ElementLine {
        var depth: Int
        var role: String
        var frame: (x: Double, y: Double, width: Double, height: Double)
        var detail: String
        var focused: Bool
        var leaving: Bool

        /// Moves a trailing "focused" and "leaving" (printed in that order, after the detail) to flags.
        mutating func takeFlags() {
            leaving = Self.take("leaving", from: &detail)
            focused = Self.take("focused", from: &detail)
        }

        private static func take(_ word: String, from detail: inout String) -> Bool {
            if detail == word { detail = ""; return true }
            if detail.hasSuffix(" " + word) { detail.removeLast(word.count + 1); return true }
            return false
        }
    }

    /// The elements from `index` on that are at `depth` or deeper, as siblings with their children.
    private static func buildElements(_ items: [ElementLine], _ index: inout Int, depth: Int) -> [JSON] {
        var out: [JSON] = []
        while index < items.count, items[index].depth >= depth {
            let item = items[index]
            index += 1
            let children = buildElements(items, &index, depth: item.depth + 1)
            out.append([
                "role": .string(item.role),
                "frame": frameJSON(item.frame.x, item.frame.y, item.frame.width, item.frame.height),
                "detail": .string(item.detail),
                "focused": .bool(item.focused),
                "leaving": .bool(item.leaving),
                "children": .array(children),
            ])
        }
        return out
    }

    /// `Role (x, y, WxH) detail [focused] [leaving]`, indented two spaces per level; nil for any
    /// other line. The detail still ends with the flags; `takeFlags` removes them once any
    /// continuation lines are joined on.
    static func parseElementLine(_ line: String) -> ElementLine? {
        let spaces = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(spaces)
        guard spaces % 2 == 0, let open = rest.firstIndex(of: "("), open > rest.startIndex,
              rest[rest.index(before: open)] == " ",
              let close = rest[open...].firstIndex(of: ")") else { return nil }
        let role = String(rest[rest.startIndex..<rest.index(before: open)])
        guard let first = role.first, first.isUppercase, !role.contains(" ") else { return nil }
        let parts = rest[rest.index(after: open)..<close].split(separator: ",").map { $0.filter { $0 != " " } }
        guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        let wh = parts[2].split(separator: "x")
        guard wh.count == 2, let w = Double(wh[0]), let h = Double(wh[1]) else { return nil }
        var detail = String(rest[rest.index(after: close)...])
        if detail.hasPrefix(" ") { detail.removeFirst() }
        return ElementLine(depth: spaces / 2, role: role, frame: (x, y, w, h), detail: detail, focused: false, leaving: false)
    }
}
