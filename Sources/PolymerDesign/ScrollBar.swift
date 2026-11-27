// A scroll bar in the house look: a square thumb on a 1-point line. It draws
// a position it is given, or follows a `ScrollView` through its
// `ScrollViewReader` proxy: `PScrollBar(proxy)`.
import PolymerBase
import PolymerUI

public enum PScrollAxis: Sendable { case vertical, horizontal }

/// `PScrollBar(visible: 0.25, position: 0.5)`: the thumb is `visible` of the
/// track long and sits at `position` (0 at the start, 1 at the end).
///
/// `PScrollBar(proxy)` reads both from the scroll view, and redraws as it
/// scrolls; in an `HStack`/`VStack` it takes the other axis from the view.
public struct PScrollBar: View {
    enum Source {
        case values(visible: Double, position: Double)
        case proxy(ScrollViewProxy)
    }

    let source: Source
    let fixedAxis: PScrollAxis?
    let name: String

    public init(visible: Double, position: Double, axis: PScrollAxis = .vertical, name: String = "scroll-bar") {
        source = .values(visible: min(max(visible, 0), 1), position: min(max(position, 0), 1))
        fixedAxis = axis
        self.name = name
    }

    /// Follows the `ScrollView` in the same `ScrollViewReader`.
    public init(_ proxy: ScrollViewProxy, axis: PScrollAxis? = nil, name: String = "scroll-bar") {
        source = .proxy(proxy)
        fixedAxis = axis
        self.name = name
    }

    /// The thumb and axis to draw, from the given values or the scroll view.
    private var resolved: (visible: Double, position: Double, axis: PScrollAxis) {
        switch source {
        case .values(let v, let p):
            return (v, p, fixedAxis ?? .vertical)
        case .proxy(let proxy):
            // Read through the proxy so this body runs again when it scrolls.
            let metrics = proxy.metrics
            let axis = fixedAxis ?? (metrics.axes.contains(.vertical) ? .vertical : .horizontal)
            let swiftAxis: Axis = axis == .vertical ? .vertical : .horizontal
            return (proxy.visibleFraction(swiftAxis), proxy.position(swiftAxis), axis)
        }
    }

    public var body: some View {
        let (visible, position, axis) = resolved
        let name = name
        Component(name: name, role: "ScrollBar", title: "Scroll bar") { info in
            let t = info.theme
            let w = t.size.scrollBar
            GeometryReader { p in
                let length = axis == .vertical ? p.size.height : p.size.width
                let thumb = max(length * visible, 2 * w)
                let at = (length - thumb) * position
                ZStack(alignment: .topLeading) {
                    if axis == .vertical {
                        Rectangle().fill(t.gray.line).frame(width: t.line).offset(x: (w - t.line) / 2)
                        Rectangle().fill(t.gray.strongLine).frame(width: w, height: thumb).offset(y: at)
                    } else {
                        Rectangle().fill(t.gray.line).frame(height: t.line).offset(y: (w - t.line) / 2)
                        Rectangle().fill(t.gray.strongLine).frame(width: thumb, height: w).offset(x: at)
                    }
                }
            }
            .frame(width: axis == .vertical ? w : nil, height: axis == .horizontal ? w : nil)
            .accessibilityHidden(true)
        }
    }
}
