// Things a pointer can act on: Button and tap handlers.
import PolymerBase

/// Runs `action` when clicked: pressed and released over it, or Space or
/// Return while it has focus. Its look comes from the `ButtonStyle` in the
/// environment (`.buttonStyle(_:)`); the default draws the label as it is.
/// The whole label area is clickable.
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
        let style = c.environment.buttonStyle
        if style is PlainButtonStyle {
            n.setChild(0, label, c)
        } else {
            func styled<S: ButtonStyle>(_ s: S) {
                let label = label
                let l = ButtonStyleConfiguration.Label { existing, c in reconcile(label, existing, c) }
                n.setChild(0, StyledButtonBody(style: s, label: l, pressed: n.pressed), c)
            }
            styled(style)
        }
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
    /// Whether the pointer is holding the button down; button styles read it as `isPressed`.
    let pressed = StateStorage(false)
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
