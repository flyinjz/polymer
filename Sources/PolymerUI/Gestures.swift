// Drag gestures: `DragGesture` with `minimumDistance`, `.onChanged`, `.onEnded`,
// and `.gesture(_:)` / `.highPriorityGesture(_:)` / `.simultaneousGesture(_:)`.
import PolymerBase

/// A dragging motion that invokes callbacks as the pointer moves after exceeding `minimumDistance`.
public struct DragGesture {
    public struct Value: Equatable, Sendable {
        public var startLocation: Point
        public var location: Point
        public var translation: Size
        public var predictedEndLocation: Point
        public var predictedEndTranslation: Size

        public init(startLocation: Point, location: Point, predictedEndLocation: Point? = nil) {
            self.startLocation = startLocation
            self.location = location
            self.translation = Size(width: location.x - startLocation.x, height: location.y - startLocation.y)
            let pred = predictedEndLocation ?? location
            self.predictedEndLocation = pred
            self.predictedEndTranslation = Size(width: pred.x - startLocation.x, height: pred.y - startLocation.y)
        }
    }

    public var minimumDistance: Double
    var onChangedAction: (@MainActor (Value) -> Void)?
    var onEndedAction: (@MainActor (Value) -> Void)?

    public init(minimumDistance: Double = 10) {
        self.minimumDistance = max(0, minimumDistance)
    }

    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var copy = self
        copy.onChangedAction = action
        return copy
    }

    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var copy = self
        copy.onEndedAction = action
        return copy
    }
}

enum DragGesturePriority {
    case normal
    case high
    case simultaneous
}

extension View {
    public func gesture(_ gesture: DragGesture) -> some View {
        DragGestureView(content: self, gesture: gesture, priority: .normal)
    }

    public func highPriorityGesture(_ gesture: DragGesture) -> some View {
        DragGestureView(content: self, gesture: gesture, priority: .high)
    }

    public func simultaneousGesture(_ gesture: DragGesture) -> some View {
        DragGestureView(content: self, gesture: gesture, priority: .simultaneous)
    }
}

struct DragGestureView<Content: View>: View, PrimitiveView {
    let content: Content
    let gesture: DragGesture
    let priority: DragGesturePriority

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? DragGestureNode) ?? DragGestureNode()
        n.gesture = gesture
        n.priority = priority
        n.isEnabled = c.environment.isEnabled
        n.setChild(0, content, c)
        return n
    }
}

final class DragGestureNode: PassthroughNode {
    var gesture = DragGesture()
    var priority: DragGesturePriority = .normal
    var isEnabled: Bool = true

    override func hitTest(_ p: Point) -> Node? {
        if let h = super.hitTest(p) { return h }
        return isEnabled && contentFrame.contains(p) ? self : nil
    }
}

/// Active drag state managed by `ViewTree` across pointerDown/pointerMoved/pointerUp/pointerExited.
@MainActor
struct ActiveDragSession {
    weak var node: DragGestureNode?
    var startLocation: Point
    var lastLocation: Point
    var isActive: Bool
}
