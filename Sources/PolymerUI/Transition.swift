// Transitions, as in SwiftUI: how a view comes in when it is inserted and
// goes out when it is removed, under an animation (`withAnimation`,
// `.animation(_:value:)`). Without `.transition(_:)` a view fades. A removed
// view stays drawn where it was until its transition ends (it no longer
// takes space, can't be clicked, and shows as "leaving" in the element tree).
import PolymerBase
import PolymerRender

/// A side of a rectangle.
public enum Edge: Hashable, Sendable {
    case top, leading, bottom, trailing

    var opposite: Edge {
        switch self { case .top: .bottom; case .bottom: .top; case .leading: .trailing; case .trailing: .leading }
    }
}

/// How a view is inserted and removed.
public struct AnyTransition: Hashable, Sendable {
    /// What a transition does to a view when it is fully out: drawn with
    /// `opacity`, moved by `offset` points plus `sizeOffset` times its own
    /// size, and scaled by `scale` about `anchor`.
    struct Effect: Hashable, Sendable {
        var opacity = 1.0
        var offset = Point.zero
        var sizeOffset = Point.zero
        var scale = 1.0
        var anchor = UnitPoint.center

        func combined(with o: Effect) -> Effect {
            Effect(opacity: opacity * o.opacity, offset: offset + o.offset, sizeOffset: sizeOffset + o.sizeOffset,
                   scale: scale * o.scale, anchor: scale != 1 ? anchor : o.anchor)
        }

        /// The effect at `phase` (1: fully in, 0: fully out), for a view of `size`.
        func state(at phase: Double, size: Size) -> (opacity: Double, offset: Point, scale: Double) {
            let k = 1 - phase
            let o = 1 + (opacity - 1) * k
            let shift = Point(x: offset.x + sizeOffset.x * size.width, y: offset.y + sizeOffset.y * size.height)
            return (min(max(o, 0), 1), shift * k, max(0, 1 + (scale - 1) * k))
        }
    }

    let insertion: Effect
    let removal: Effect

    init(_ both: Effect) { insertion = both; removal = both }
    init(insertion: Effect, removal: Effect) { self.insertion = insertion; self.removal = removal }

    /// No change: the view appears and disappears at once.
    public static let identity = AnyTransition(Effect())
    /// Fades in and out (the transition of views that don't name one).
    public static let opacity = AnyTransition(Effect(opacity: 0))
    /// Moves in from `edge` and out to it, by the view's own size.
    public static func move(edge: Edge) -> AnyTransition {
        let s: Point = switch edge {
        case .top: Point(x: 0, y: -1)
        case .bottom: Point(x: 0, y: 1)
        case .leading: Point(x: -1, y: 0)
        case .trailing: Point(x: 1, y: 0)
        }
        return AnyTransition(Effect(sizeOffset: s))
    }
    /// Grows from nothing about its centre, and shrinks away.
    public static var scale: AnyTransition { .scale(scale: 0) }
    /// Grows from `scale` times its size about `anchor`, and shrinks back to it.
    public static func scale(scale: Double, anchor: UnitPoint = .center) -> AnyTransition {
        AnyTransition(Effect(scale: max(0, scale), anchor: anchor))
    }
    /// Moves in from (x, y) points away and out to there.
    public static func offset(x: Double = 0, y: Double = 0) -> AnyTransition {
        AnyTransition(Effect(offset: Point(x: x, y: y)))
    }
    /// Comes in from the leading edge and leaves towards the trailing edge.
    public static var slide: AnyTransition { .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)) }
    /// Comes in from `edge`, fading in, and leaves towards the opposite edge, fading out.
    public static func push(from edge: Edge) -> AnyTransition {
        .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .move(edge: edge.opposite).combined(with: .opacity))
    }
    /// One transition for insertion and another for removal.
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        AnyTransition(insertion: insertion.insertion, removal: removal.removal)
    }
    /// Both transitions at once.
    public func combined(with other: AnyTransition) -> AnyTransition {
        AnyTransition(insertion: insertion.combined(with: other.insertion), removal: removal.combined(with: other.removal))
    }

    /// The transition for `leaf`, part of the inserted or removed `root`: the
    /// nearest `.transition(_:)` between them, or a fade.
    @MainActor static func find(from leaf: Node, to root: Node) -> AnyTransition {
        var n: Node? = leaf
        while let x = n {
            if let t = x as? TransitionNode { return t.declared }
            if x === root { break }
            n = x.parent
        }
        return .opacity
    }
}

extension View {
    /// How the view comes in when inserted and goes out when removed, under an animation.
    public func transition(_ t: AnyTransition) -> some View { TransitionView(content: self, transition: t) }
}

struct TransitionView<Content: View>: View, PrimitiveView {
    let content: Content
    let transition: AnyTransition
    var body: Never { fatalError("TransitionView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TransitionNode) ?? TransitionNode()
        n.declared = transition
        n.setChild(0, content, c)
        return n
    }
}

/// Carries a view's transition; the views it contains are what move.
final class TransitionNode: PassthroughNode {
    var declared = AnyTransition.opacity
}

/// A node on its way in or out.
struct ActiveTransition {
    let effect: AnyTransition.Effect
    /// 1 when fully in, 0 when fully out.
    var phase: Animated<Double>
    let removing: Bool
}

/// A removed child still drawn while it leaves.
struct Ghost {
    let node: Node
    /// Where it was among its parent's children.
    let index: Int
    /// What moves: the nodes it shows (`flattened`).
    let leaves: [Node]
}

extension Node {
    /// True for a node that is leaving, or inside one that is.
    var isLeaving: Bool {
        var n: Node? = self
        while let x = n {
            if x.transition?.removing == true { return true }
            n = x.parent
        }
        return false
    }
}
