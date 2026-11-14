// Things a pointer can act on: Button and tap handlers.
import PolymerBase

/// Runs `action` when clicked. Unstyled for now: it looks like its label
/// (button styles come with PolymerDesign). The whole label area is clickable.
public struct Button<Label: View>: View, PrimitiveView {
    let action: @MainActor () -> Void
    let label: Label

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action; self.label = label()
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let reuse = (existing as? TapNode).flatMap { $0.isButton ? $0 : nil }
        let n = reuse ?? TapNode(isButton: true)
        n.action = action
        n.setChild(0, label, c)
        return n
    }
}

extension Button where Label == Text {
    public init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

extension View {
    /// Runs `action` when the view is clicked. Only what the view draws is clickable.
    public func onTapGesture(perform action: @escaping @MainActor () -> Void) -> some View {
        TapView(content: self, action: action)
    }
}

struct TapView<Content: View>: View, PrimitiveView {
    let content: Content
    let action: @MainActor () -> Void
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let reuse = (existing as? TapNode).flatMap { $0.isButton ? nil : $0 }
        let n = reuse ?? TapNode(isButton: false)
        n.action = action
        n.setChild(0, content, c)
        return n
    }
}

final class TapNode: PassthroughNode {
    let isButton: Bool
    var action: (@MainActor () -> Void)?
    init(isButton: Bool) { self.isButton = isButton; super.init() }

    override var role: String { "Button" }
    override var isElement: Bool { isButton }
    override var tapAction: (@MainActor () -> Void)? { action }
    override var acceptsFocus: Bool { isButton }

    /// Space and Return press a focused button.
    override func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isButton, press.phase == .down, press.modifiers.isEmpty,
              press.key == .space || press.key == .return, let action else { return .ignored }
        action()
        return .handled
    }

    override func hitTest(_ p: Point) -> Node? {
        if let h = super.hitTest(p) { return h }
        return isButton && contentFrame.contains(p) ? self : nil
    }
}
