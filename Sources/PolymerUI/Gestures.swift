// Drag gestures, as in SwiftUI: `.gesture(DragGesture().onChanged { }.onEnded { })`.
// A drag starts once the pointer, held down on the view, has moved
// `minimumDistance` points; from then on the press belongs to the drag (a
// button under it is not clicked). Only what the view draws starts a drag,
// as with tap handlers.
import PolymerBase

/// Where gesture locations are measured from.
public enum CoordinateSpace: Hashable, Sendable {
    /// The view's own top-leading corner.
    case local
    /// The window's (the tree's) top-leading corner.
    case global
}

/// A drag: the pointer held down and moved.
public struct DragGesture: Sendable {
    /// What a drag reports while it runs and when it ends.
    public struct Value: Equatable, Sendable {
        /// Seconds (`ViewTree.time`) of this event.
        public var time: Double
        public var location: Point
        public var startLocation: Point
        /// `location` minus `startLocation`.
        public var translation: Size
        /// Points per second, from the last tenth of a second of movement.
        public var velocity: Size
        /// Where the drag would stop if the pointer were let go now and slowed down as a flick does.
        public var predictedEndLocation: Point
        public var predictedEndTranslation: Size
    }

    public var minimumDistance: Double
    public var coordinateSpace: CoordinateSpace
    var changed: (@MainActor (Value) -> Void)?
    var ended: (@MainActor (Value) -> Void)?

    public init(minimumDistance: Double = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = max(0, minimumDistance)
        self.coordinateSpace = coordinateSpace
    }

    /// Runs `action` with each movement of the drag.
    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var g = self; g.changed = action; return g
    }
    /// Runs `action` once when the pointer comes up after a drag.
    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var g = self; g.ended = action; return g
    }
}

extension View {
    /// Attaches a drag gesture to the view.
    public func gesture(_ gesture: DragGesture) -> some View { DragGestureView(content: self, gesture: gesture) }
}

struct DragGestureView<Content: View>: View, PrimitiveView {
    let content: Content
    let gesture: DragGesture
    var body: Never { fatalError("DragGestureView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? DragGestureNode) ?? DragGestureNode()
        n.gesture = gesture
        n.isEnabled = c.environment.isEnabled
        n.setChild(0, content, c)
        return n
    }
}

/// How long a flick keeps going: the predicted end is this many seconds of the release velocity away.
let flickProjection = 0.5

final class DragGestureNode: PassthroughNode {
    var gesture = DragGesture()
    var isEnabled = true

    // The drag in progress, in screen points.
    private var start: Point?
    private var startTime = 0.0
    private(set) var isDragging = false
    /// Recent positions and times, for the velocity.
    private var samples: [(t: Double, p: Point)] = []

    /// The pointer went down on the view at `p` (screen points). Returns true
    /// when the drag has begun at once (a minimum distance of 0).
    func pointerDown(at p: Point, time: Double) -> Bool {
        start = p; startTime = time; isDragging = false
        samples.removeAll(keepingCapacity: true)
        samples.append((time, p))
        if gesture.minimumDistance == 0 { isDragging = true; gesture.changed?(value(at: p, time: time)) }
        return isDragging
    }

    /// The held pointer moved. Returns true when the drag has begun (now or earlier).
    func pointerMoved(to p: Point, time: Double) -> Bool {
        guard let s = start, isMounted else { return false }
        samples.append((time, p))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
        if !isDragging {
            let dx = p.x - s.x, dy = p.y - s.y
            guard (dx * dx + dy * dy).squareRoot() >= gesture.minimumDistance else { return false }
            isDragging = true
        }
        gesture.changed?(value(at: p, time: time))
        return true
    }

    /// The pointer came up. Returns true when it ended a drag.
    func pointerUp(at p: Point, time: Double) -> Bool {
        defer { start = nil; isDragging = false }
        guard start != nil, isDragging, isMounted else { return false }
        if samples.last?.p != p { samples.append((time, p)) }
        gesture.ended?(value(at: p, time: time))
        return true
    }

    /// The press ended some other way (the pointer left, the view went away).
    func cancel() { start = nil; isDragging = false }

    private func value(at p: Point, time: Double) -> DragGesture.Value {
        let s = start ?? p
        // Local: from the view's top-leading corner where it is now.
        let o: Point = gesture.coordinateSpace == .local ? screenFrame.origin : .zero
        let loc = Point(x: p.x - o.x, y: p.y - o.y), st = Point(x: s.x - o.x, y: s.y - o.y)
        var v = Size(width: 0, height: 0)
        if let first = samples.last(where: { time - $0.t >= 0.1 }) ?? samples.first, time - first.t > 0 {
            v = Size(width: (p.x - first.p.x) / (time - first.t), height: (p.y - first.p.y) / (time - first.t))
        }
        let tr = Size(width: loc.x - st.x, height: loc.y - st.y)
        let end = Point(x: loc.x + v.width * flickProjection, y: loc.y + v.height * flickProjection)
        return DragGesture.Value(time: time, location: loc, startLocation: st, translation: tr, velocity: v,
                                 predictedEndLocation: end,
                                 predictedEndTranslation: Size(width: end.x - st.x, height: end.y - st.y))
    }

    override func unmount() {
        cancel()
        super.unmount()
    }
}
