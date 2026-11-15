// The accessibility tree (DESIGN D11): what a screen reader sees. Built from
// the node tree on request, never kept up to date in the background, so it
// costs nothing until something asks. Roles come from the views (text,
// buttons, images, scroll views, focusable views); `.accessibilityLabel`,
// `.accessibilityValue`, `.accessibilityHint`, `.accessibilityHidden`,
// `.accessibilityAddTraits` and `.accessibilityElement(children:)` adjust
// it, as in SwiftUI. The platform layer will hand it to UI Automation and
// NSAccessibility; headless tools print it.
import PolymerBase

/// What kind of thing an accessibility element is.
public enum AccessibilityRole: String, Sendable {
    case staticText = "text"
    case button
    case image
    case textField = "text field"
    case scrollArea = "scroll area"
    case group
    case focusable = "focusable"
}

/// Extra facts about an element, as in SwiftUI.
public struct AccessibilityTraits: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = AccessibilityTraits(rawValue: 1 << 1)
    public static let isSelected = AccessibilityTraits(rawValue: 1 << 2)
    public static let isImage = AccessibilityTraits(rawValue: 1 << 3)
    public static let isStaticText = AccessibilityTraits(rawValue: 1 << 4)
    public static let isLink = AccessibilityTraits(rawValue: 1 << 5)

    static let names: [(AccessibilityTraits, String)] = [
        (.isButton, "button"), (.isHeader, "header"), (.isSelected, "selected"),
        (.isImage, "image"), (.isStaticText, "text"), (.isLink, "link"),
    ]
}

/// How an element relates to the elements inside it.
public enum AccessibilityChildBehavior: Hashable, Sendable {
    /// The children are left out; the element stands for them (give it a label).
    case ignore
    /// The children's labels are joined into this element's label.
    case combine
    /// The element is a group that holds its children as elements.
    case contain
}

/// One element of the accessibility tree.
public struct AccessibilityElement: Sendable {
    public var role: AccessibilityRole
    public var label: String
    public var value: String?
    public var hint: String?
    public var traits: AccessibilityTraits
    /// Where it is on screen, in points.
    public var frame: Rect
    public var isEnabled: Bool
    public var isFocused: Bool
    public var children: [AccessibilityElement]
    /// The node it stands for, to act on it.
    let nodeID: ObjectIdentifier?

    /// The element and its children as text, one per line, indented.
    public func dump(into out: inout String, depth: Int = 0) {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        out += String(repeating: "  ", count: depth)
        out += "\(role.rawValue) (\(n(frame.minX)), \(n(frame.minY)), \(n(frame.width))x\(n(frame.height)))"
        if !label.isEmpty { out += " \"\(label)\"" }
        if let value { out += " value \"\(value)\"" }
        if let hint { out += " hint \"\(hint)\"" }
        let t = AccessibilityTraits.names.filter { traits.contains($0.0) && !role.implies($0.0) }.map(\.1)
        if !t.isEmpty { out += " [\(t.joined(separator: ", "))]" }
        if !isEnabled { out += " disabled" }
        if isFocused { out += " focused" }
        out += "\n"
        for c in children { c.dump(into: &out, depth: depth + 1) }
    }
}

extension AccessibilityRole {
    /// Traits the role already says (not repeated in the dump).
    func implies(_ t: AccessibilityTraits) -> Bool {
        switch self {
        case .button: t == .isButton
        case .image: t == .isImage
        case .staticText: t == .isStaticText
        default: false
        }
    }
}

// MARK: Modifiers

extension View {
    /// What a screen reader says for the view, instead of its text.
    public func accessibilityLabel(_ label: String) -> some View { AccessibilityView(content: self, edit: .label(label)) }
    /// The view's current value ("40%", "On").
    public func accessibilityValue(_ value: String) -> some View { AccessibilityView(content: self, edit: .value(value)) }
    /// What happens when the view is used ("Plays the album").
    public func accessibilityHint(_ hint: String) -> some View { AccessibilityView(content: self, edit: .hint(hint)) }
    /// Leaves the view and everything in it out of the accessibility tree.
    public func accessibilityHidden(_ hidden: Bool) -> some View { AccessibilityView(content: self, edit: .hidden(hidden)) }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { AccessibilityView(content: self, edit: .traits(traits)) }
    /// Makes the view one element, with its children left out, combined into it, or contained in it.
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
        AccessibilityView(content: self, edit: .element(children))
    }
}

enum AccessibilityEdit {
    case label(String), value(String), hint(String), hidden(Bool), traits(AccessibilityTraits)
    case element(AccessibilityChildBehavior)
}

struct AccessibilityView<Content: View>: View, PrimitiveView {
    let content: Content
    let edit: AccessibilityEdit
    var body: Never { fatalError("AccessibilityView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? AccessibilityNode) ?? AccessibilityNode()
        n.edit = edit
        n.setChild(0, content, c)
        return n
    }
}

/// Carries one accessibility modifier; lays out and draws as its content.
final class AccessibilityNode: PassthroughNode {
    var edit = AccessibilityEdit.hidden(false)
}

// MARK: Building the tree

/// What the modifiers between an element and the view it describes say.
struct AccessibilityEdits {
    var label: String?, value: String?, hint: String?
    var hidden = false
    var traits: AccessibilityTraits = []
    var element: AccessibilityChildBehavior?

    mutating func apply(_ e: AccessibilityEdit) {
        switch e {
        // The modifier nearest the view wins, as in SwiftUI; edits are applied outermost first.
        case .label(let s): label = s
        case .value(let s): value = s
        case .hint(let s): hint = s
        case .hidden(let h): hidden = hidden || h
        case .traits(let t): traits.formUnion(t)
        case .element(let b): element = b
        }
    }
    var isEmpty: Bool { label == nil && value == nil && hint == nil && traits.isEmpty && element == nil }
}

extension Node {
    /// The accessibility elements of this subtree, with `edits` from the modifiers above it.
    func accessibilityElements(_ edits: AccessibilityEdits, focused: Node?) -> [AccessibilityElement] {
        var edits = edits
        if let a = self as? AccessibilityNode { edits.apply(a.edit) }
        if edits.hidden { return [] }
        if self is AccessibilityNode {
            return children.flatMap { $0.accessibilityElements(edits, focused: focused) }
        }
        let own = ownAccessibility
        guard own != nil || edits.element != nil else {
            // Not an element: the modifiers apply to the elements inside.
            return children.flatMap { $0.accessibilityElements(edits, focused: focused) }
        }
        let role = own?.role ?? .group
        let behaviour = edits.element ?? own?.children ?? .contain
        let inner = behaviour == .ignore ? [] : children.flatMap { $0.accessibilityElements(AccessibilityEdits(), focused: focused) }
        var label = edits.label ?? own?.label ?? ""
        if edits.label == nil, behaviour == .combine { label = ([label] + inner.flatMap { $0.combinedLabels }).filter { !$0.isEmpty }.joined(separator: ", ") }
        var traits = own?.traits ?? []
        traits.formUnion(edits.traits)
        var isFocused = focused === self
        if !isFocused, let f = focused, behaviour != .contain { isFocused = f.isInside(self) }
        return [AccessibilityElement(role: role, label: label, value: edits.value ?? own?.value, hint: edits.hint, traits: traits,
                                     frame: screenFrame, isEnabled: own?.isEnabled ?? true, isFocused: isFocused,
                                     children: behaviour == .contain ? inner : [], nodeID: ObjectIdentifier(self))]
    }

    /// What the node is by itself, for nodes that are accessibility elements of their own.
    var ownAccessibility: (role: AccessibilityRole, label: String, value: String?, traits: AccessibilityTraits,
                           children: AccessibilityChildBehavior, isEnabled: Bool)? {
        switch self {
        case let t as TextNode: return (.staticText, t.string, nil, .isStaticText, .ignore, true)
        case let b as TapNode where b.isButton: return (.button, "", nil, .isButton, .combine, b.isEnabled)
        case is ImageNode: return (.image, "", nil, .isImage, .ignore, true)
        case is ScrollNode: return (.scrollArea, "", nil, [], .contain, true)
        case is FocusableNode: return (.focusable, "", nil, [], .combine, true)
        default: return nil
        }
    }

    /// True when this node is `ancestor` or inside it.
    func isInside(_ ancestor: Node) -> Bool {
        var n: Node? = self
        while let x = n { if x === ancestor { return true }; n = x.parent }
        return false
    }
}

extension AccessibilityElement {
    /// The labels a combining parent takes from this element.
    var combinedLabels: [String] { label.isEmpty ? children.flatMap(\.combinedLabels) : [label] }
}
