// Semantic accessibility tree export for agents, screen readers, and headless checks.
import PolymerBase

public enum AccessibilityRole: String, Equatable, Hashable, Sendable {
    case application
    case group
    case text
    case button
    case textField
    case textEditor
    case image
    case scrollArea
    case grid
    case list
    case menu
    case divider
    case shape
    case unknown
}

public struct AccessibilityNode: Equatable, Sendable {
    public var id: String
    public var stablePath: String
    public var stableID: StableID
    public var role: AccessibilityRole
    public var label: String
    public var value: String?
    public var frame: Rect
    public var isEnabled: Bool
    public var isFocused: Bool
    public var actions: [String]
    public var children: [AccessibilityNode]

    public init(
        id: String,
        stablePath: String,
        stableID: StableID,
        role: AccessibilityRole,
        label: String,
        value: String?,
        frame: Rect,
        isEnabled: Bool,
        isFocused: Bool,
        actions: [String],
        children: [AccessibilityNode]
    ) {
        self.id = id
        self.stablePath = stablePath
        self.stableID = stableID
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
        self.children = children
    }

    /// Deterministic JSON representation (keys sorted on serialization via `PolymerBase.JSON`).
    public func toJSON() -> JSON {
        var obj: [String: JSON] = [
            "id": .string(id),
            "stablePath": .string(stablePath),
            "stableID": .string(stableID.description),
            "role": .string(role.rawValue),
            "label": .string(label),
            "frame": .object([
                "x": .number(frame.minX),
                "y": .number(frame.minY),
                "width": .number(frame.width),
                "height": .number(frame.height),
            ]),
            "isEnabled": .bool(isEnabled),
            "isFocused": .bool(isFocused),
            "actions": .array(actions.map { .string($0) }),
            "children": .array(children.map { $0.toJSON() }),
        ]
        if let value {
            obj["value"] = .string(value)
        } else {
            obj["value"] = .null
        }
        return .object(obj)
    }

    /// Deterministic, human- and agent-readable indented description of the accessibility tree.
    public func describeTree() -> String {
        var out = ""
        writeDescription(into: &out, depth: 0)
        return out
    }

    private func writeDescription(into out: inout String, depth: Int) {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        out += String(repeating: "  ", count: depth)
        out += role.rawValue
        if !label.isEmpty { out += " \"\(label)\"" }
        if let value { out += " value=\"\(value)\"" }
        out += " id=\"\(id)\""
        out += " (\(n(frame.minX)), \(n(frame.minY)), \(n(frame.width))x\(n(frame.height)))"
        if !actions.isEmpty { out += " actions=[\(actions.joined(separator: ", "))]" }
        if !isEnabled { out += " disabled" }
        if isFocused { out += " focused" }
        out += "\n"
        for child in children {
            child.writeDescription(into: &out, depth: depth + 1)
        }
    }

    /// Depth-first search returning the first matching accessibility node.
    public func first(where predicate: (AccessibilityNode) -> Bool) -> AccessibilityNode? {
        if predicate(self) { return self }
        for child in children {
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }

    /// Finds the first node with the given `id`.
    public func find(id: String) -> AccessibilityNode? {
        first { $0.id == id }
    }

    /// Collects all matching accessibility nodes in depth-first order.
    public func all(where predicate: (AccessibilityNode) -> Bool) -> [AccessibilityNode] {
        var out: [AccessibilityNode] = []
        collectAll(where: predicate, into: &out)
        return out
    }

    private func collectAll(where predicate: (AccessibilityNode) -> Bool, into out: inout [AccessibilityNode]) {
        if predicate(self) { out.append(self) }
        for child in children { child.collectAll(where: predicate, into: &out) }
    }
}

// MARK: ViewTree export

private struct PendingTraits {
    var explicitID: String? = nil
    var actions: [String] = []
    var focused: Bool = false

    mutating func addAction(_ action: String) {
        if !actions.contains(action) { actions.append(action) }
    }
}

extension ViewTree {
    /// Exports a deterministic semantic accessibility tree of the current UI state.
    public func accessibilityTree() -> AccessibilityNode {
        update()
        var rootChildren: [AccessibilityNode] = []
        if let root {
            rootChildren.append(contentsOf: buildAccessibility(root, focused: state.focused, pending: PendingTraits()))
        }
        if let menu = contextMenuRoot {
            rootChildren.append(contentsOf: buildAccessibility(menu, focused: state.focused, pending: PendingTraits()))
        }
        return AccessibilityNode(
            id: "application",
            stablePath: "Application",
            stableID: StableID("Application"),
            role: .application,
            label: "Application",
            value: nil,
            frame: Rect(origin: .zero, size: size),
            isEnabled: true,
            isFocused: false,
            actions: [],
            children: rootChildren
        )
    }

    private func buildAccessibility(_ node: Node, focused: Node?, pending: PendingTraits) -> [AccessibilityNode] {
        var traits = pending
        if let explicit = node.accessibilityID {
            traits.explicitID = traits.explicitID ?? explicit
        }
        if let focused, focused === node {
            traits.focused = true
        }
        if let cm = node as? ContextMenuNode, cm.isEnabled {
            traits.addAction("contextMenu")
        }
        if let dg = node as? DragGestureNode, dg.isEnabled {
            traits.addAction("drag")
        }
        if let fn = node as? FocusableNode, fn.isFocusable {
            traits.addAction("focus")
        }
        if let tn = node as? TapNode, !tn.isButton, tn.isEnabled {
            traits.addAction("press")
        }

        if let layer = node as? LayerNode {
            // Preserve back-to-front order while passing traits to the content child only.
            let contentIdx = 0
            let layerIdx = 1
            let contentNodes = buildAccessibility(layer.children[contentIdx], focused: focused, pending: traits)
            let layerNodes = buildAccessibility(layer.children[layerIdx], focused: focused, pending: PendingTraits())
            return layer.behind ? (layerNodes + contentNodes) : (contentNodes + layerNodes)
        }

        if !node.isElement {
            var out: [AccessibilityNode] = []
            var carry = traits
            for c in node.children {
                let built = buildAccessibility(c, focused: focused, pending: carry)
                if !built.isEmpty {
                    carry = PendingTraits()
                }
                out.append(contentsOf: built)
            }
            return out
        }

        var role: AccessibilityRole
        var label: String = ""
        var value: String? = nil
        var isEnabled = true
        var actions = traits.actions

        func addAction(_ a: String) {
            if !actions.contains(a) { actions.append(a) }
        }

        switch node {
        case let t as TextNode:
            role = .text
            label = t.string
        case let b as TapNode where b.isButton:
            role = .button
            label = (b.first { $0 is TextNode } as? TextNode)?.string ?? ""
            isEnabled = b.isEnabled
            if isEnabled {
                addAction("press")
                addAction("focus")
            }
        case let tf as TextFieldNode:
            role = .textField
            label = tf.placeholder
            value = tf.editorState.text
            isEnabled = tf.isEnabled
            if isEnabled {
                addAction("focus")
                addAction("edit")
            }
        case let te as TextEditorNode:
            role = .textEditor
            label = ""
            value = te.editorState.text
            isEnabled = te.isEnabled
            if isEnabled {
                addAction("focus")
                addAction("edit")
            }
        case let img as ImageNode:
            role = .image
            label = img.detail
        case let sc as ScrollNode:
            role = .scrollArea
            value = sc.detail
            addAction("scroll")
        case let g as LazyGridNode:
            role = .grid
            value = g.detail
        case let ls as LazyStackNode:
            role = .list
            value = ls.detail
        case is ContextMenuContainerNode:
            role = .menu
            label = "ContextMenu"
        case is DividerNode:
            role = .divider
        case is FillNode, is ShapeNode, is BorderNode, is BackdropBlurNode:
            role = .shape
            label = node.role
            value = node.detail.isEmpty ? nil : node.detail
        case is StackNode, is ZStackNode:
            role = .group
            label = node.role
        case is SpacerNode:
            role = .unknown
            label = "Spacer"
        default:
            role = .group
            label = node.role
        }

        let canonicalOrder = ["press", "focus", "edit", "contextMenu", "drag", "scroll"]
        let sortedActions = canonicalOrder.filter { actions.contains($0) }
            + actions.filter { !canonicalOrder.contains($0) }.sorted()

        var childNodes: [AccessibilityNode] = []
        for c in node.children {
            childNodes.append(contentsOf: buildAccessibility(c, focused: focused, pending: PendingTraits()))
        }

        let path = node.stablePath
        let id = traits.explicitID ?? path
        return [
            AccessibilityNode(
                id: id,
                stablePath: path,
                stableID: node.stableID,
                role: role,
                label: label,
                value: value,
                frame: node.screenFrame,
                isEnabled: isEnabled,
                isFocused: traits.focused,
                actions: sortedActions,
                children: childNodes
            )
        ]
    }
}
