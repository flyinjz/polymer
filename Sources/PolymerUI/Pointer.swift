// Pointer states: button styles that see whether a button is held down
// (`ButtonStyle`, `isPressed`) and `.onHover`. The tree tracks the
// pointer through `ViewTree.pointerMoved/Down/Up`.
import PolymerBase

/// How a button looks, given its label and whether it is held down (SwiftUI's `ButtonStyle`).
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ButtonStyleConfiguration
}

/// What a button style is given.
public struct ButtonStyleConfiguration {
    /// The button's label, as written.
    public struct Label: View, PrimitiveView {
        let make: @MainActor (Node?, ResolveContext) -> Node
        func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { make(existing, c) }
    }
    public let label: Label
    /// True while the pointer holds the button down over it.
    public let isPressed: Bool
}

/// Draws the label as it is. The default until PolymerDesign gives buttons a look.
public struct PlainButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension ButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension View {
    /// Sets the look of buttons in this view.
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        EnvironmentModifier(content: self) { $0.buttonStyle = style }
    }
}

/// Views used inside the framework whose name would only clutter the element tree.
protocol HiddenFromElementTree {}

/// The body of a styled button: re-evaluated when `pressed` changes.
struct StyledButtonBody<S: ButtonStyle>: View, HiddenFromElementTree {
    let style: S
    let label: ButtonStyleConfiguration.Label
    let pressed: StateStorage<Bool>
    var body: some View { style.makeBody(configuration: ButtonStyleConfiguration(label: label, isPressed: pressed.value)) }
}

// MARK: Hover

extension View {
    /// Runs `action(true)` when the pointer enters the view's frame and `action(false)` when it leaves.
    public func onHover(perform action: @escaping @MainActor (Bool) -> Void) -> some View {
        HoverView(content: self, action: action)
    }
}

struct HoverView<Content: View>: View, PrimitiveView {
    let content: Content
    let action: @MainActor (Bool) -> Void
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? HoverNode) ?? HoverNode()
        n.action = action
        c.tree.registerHover(n)
        n.setChild(0, content, c)
        return n
    }
}

final class HoverNode: PassthroughNode {
    var action: (@MainActor (Bool) -> Void)?
    var isHovered = false
}

struct WeakHoverNode { weak var node: HoverNode? }

extension Node {
    /// True when `p` (screen points) is inside the node and not cut off by an enclosing scroll view or clip.
    func isUnderPointer(_ p: Point) -> Bool {
        guard screenFrame.contains(p) else { return false }
        var n = parent
        while let x = n {
            if x.clipsContent, !x.screenFrame.contains(p) { return false }
            n = x.parent
        }
        return true
    }
}

extension TreeState {
    func registerHover(_ n: HoverNode) {
        if !hoverNodes.contains(where: { $0.node === n }) { hoverNodes.append(WeakHoverNode(node: n)) }
    }

    /// Tells hover handlers whose state changed: leaving first, then entering.
    func updateHover(_ pointer: Point?) {
        hoverNodes.removeAll { $0.node.map { !$0.isMounted } ?? true }
        let all = hoverNodes.compactMap(\.node)
        let inside = all.map { n in pointer.map { n.isUnderPointer($0) } ?? false }
        for (n, i) in zip(all, inside) where n.isHovered && !i { n.isHovered = false; n.action?(false) }
        for (n, i) in zip(all, inside) where !n.isHovered && i { n.isHovered = true; n.action?(true) }
    }
}
