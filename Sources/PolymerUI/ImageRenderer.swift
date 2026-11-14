// Headless output: render a view to an image, or print its element tree.
import PolymerBase
import PolymerRender

/// Renders a view offscreen once (SwiftUI's `ImageRenderer`). Identical
/// pixels on every OS. For a view that changes over time, keep a `ViewTree`.
@MainActor
public struct ImageRenderer<Content: View> {
    public var content: Content
    /// Pixels per point.
    public var scale: Double = 1
    /// Size offered to the view; nil uses the view's ideal size.
    public var proposedSize: ProposedViewSize = .unspecified
    public var environment = EnvironmentValues()
    /// Fill behind the view.
    public var background: Color = .clear

    public init(content: Content) { self.content = content }

    func tree() -> ViewTree {
        var e = environment
        e.displayScale = scale
        let t = ViewTree(content, environment: e)
        t.proposedSize = proposedSize
        return t
    }

    public var bitmap: Bitmap { tree().render(background: background) }

    /// The element tree as text: role, frame in points, and details, one element per line.
    public var elementTree: String { tree().elementTree }
}
