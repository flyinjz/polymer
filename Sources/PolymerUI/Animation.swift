// Animation, as in SwiftUI: `withAnimation { ... }` and
// `.animation(_:value:)` make the changes they cause move from what is on
// screen to the new value along a curve, instead of jumping. Animated today:
// view frames (position and size), opacity and fill colours. Time comes from
// `ViewTree.time`, so headless checks step it exactly; a window sets it to
// the display's frame time.
import PolymerBase
import Synchronization

/// How a change moves over time.
public struct Animation: Hashable, Sendable {
    enum Curve: Hashable, Sendable {
        /// A cubic Bézier timing curve through (0, 0), (x1, y1), (x2, y2), (1, 1), over `duration` seconds.
        case bezier(Double, Double, Double, Double, duration: Double)
        /// A damped spring that starts at rest; `response` is its period in seconds without damping.
        case spring(response: Double, damping: Double)
    }
    let curve: Curve

    public static func linear(duration: Double) -> Animation { Animation(curve: .bezier(0, 0, 1, 1, duration: duration)) }
    public static func easeIn(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 1, 1, duration: duration)) }
    public static func easeOut(duration: Double) -> Animation { Animation(curve: .bezier(0, 0, 0.58, 1, duration: duration)) }
    public static func easeInOut(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 0.58, 1, duration: duration)) }
    public static var linear: Animation { .linear(duration: 0.35) }
    public static var easeIn: Animation { .easeIn(duration: 0.35) }
    public static var easeOut: Animation { .easeOut(duration: 0.35) }
    public static var easeInOut: Animation { .easeInOut(duration: 0.35) }
    /// A spring. `dampingFraction` below 1 overshoots and settles; 1 (or more) never overshoots.
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825) -> Animation {
        Animation(curve: .spring(response: max(0.01, response), damping: max(0.01, min(dampingFraction, 1))))
    }
    public static var spring: Animation { .spring() }
    /// SwiftUI's default: a spring that doesn't overshoot.
    public static let `default` = Animation.spring(response: 0.55, dampingFraction: 1)

    /// How long until the value has arrived (a spring: until it is within 0.1% and stays there).
    public var duration: Double {
        switch curve {
        case .bezier(_, _, _, _, let d): return max(0, d)
        case .spring(let response, let z):
            let w = 2 * Double.pi / response
            if z >= 1 { return 9.2335 / w }   // (1 + u) e^-u = 0.001
            let wd = w * (1 - z * z).squareRoot()
            let k = (1 + (z * w / wd) * (z * w / wd)).squareRoot()
            return Math.log(1000 * k) / (z * w)
        }
    }

    /// Progress from 0 to 1 (a spring may pass 1 and come back) at `t` seconds after the start.
    public func progress(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= duration { return 1 }
        switch curve {
        case .bezier(let x1, let y1, let x2, let y2, let d):
            return Animation.bezier(x1, y1, x2, y2, at: t / d)
        case .spring(let response, let z):
            let w = 2 * Double.pi / response
            if z >= 1 { return 1 - Math.exp(-w * t) * (1 + w * t) }
            let wd = w * (1 - z * z).squareRoot()
            return 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + z * w / wd * Math.sin(wd * t))
        }
    }

    /// The curve's height where its x is `x` (Newton's method, then bisection if that strays).
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, at x: Double) -> Double {
        func coord(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        func slope(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
        }
        var s = x
        for _ in 0..<8 {
            let e = coord(x1, x2, s) - x
            if abs(e) < 1e-9 { return coord(y1, y2, s) }
            let d = slope(x1, x2, s)
            if abs(d) < 1e-9 { break }
            s -= e / d
        }
        var lo = 0.0, hi = 1.0
        s = x
        for _ in 0..<60 {
            let e = coord(x1, x2, s) - x
            if abs(e) < 1e-12 { break }
            if e > 0 { hi = s } else { lo = s }
            s = (lo + hi) / 2
        }
        return coord(y1, y2, s)
    }
}

/// The animation of the changes being made now (inside `withAnimation`).
enum Transaction {
    static let current = Mutex<Animation?>(nil)
}

/// Runs `body`; the views its changes affect animate with `animation` (nil: no animation).
@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    let saved = Transaction.current.withLock { a -> Animation? in let s = a; a = animation; return s }
    defer { Transaction.current.withLock { $0 = saved } }
    return try body()
}

// MARK: Animated values

/// Values that can move smoothly from one to another.
protocol Interpolatable: Equatable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

extension Double: Interpolatable {
    static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

extension Rect: Interpolatable {
    static func interpolate(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
        Rect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
             width: max(0, a.width + (b.width - a.width) * t), height: max(0, a.height + (b.height - a.height) * t))
    }
}

extension Color: Interpolatable {
    /// In sRGB-encoded values, as the canvas blends.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        func m(_ x: Double, _ y: Double) -> Double { min(max(x + (y - x) * t, 0), 1) }
        return Color(red: m(a.red, b.red), green: m(a.green, b.green), blue: m(a.blue, b.blue), opacity: m(a.opacity, b.opacity))
    }
}

/// A value that, when changed with an animation, moves from what was shown to the new value.
struct Animated<T: Interpolatable> {
    private(set) var target: T
    private var from: T
    private var start = 0.0
    private var animation: Animation?

    init(_ value: T) { target = value; from = value }

    /// Changes the value; with an animation it starts from the value shown at `now`.
    /// Returns true when an animation started.
    mutating func set(_ value: T, animation: Animation?, now: Double) -> Bool {
        guard value != target else { return false }
        if let animation, animation.duration > 0 {
            from = self.value(at: now)
            start = now
            self.animation = animation
            target = value
            return true
        }
        self.animation = nil
        target = value
        return false
    }

    /// The value shown at `now`.
    func value(at now: Double) -> T {
        guard let a = animation, now - start < a.duration else { return target }
        return T.interpolate(from, target, a.progress(now - start))
    }

    func isRunning(at now: Double) -> Bool {
        guard let a = animation else { return false }
        return now - start < a.duration
    }
}

// MARK: .animation(_:value:)

extension View {
    /// Animates the changes in this view whenever `value` changes, with `animation` (nil: none).
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        AnimationValueView(content: self, animation: animation, value: value)
    }
}

struct AnimationValueView<Content: View, V: Equatable>: View, PrimitiveView {
    let content: Content
    let animation: Animation?
    let value: V
    var body: Never { fatalError("AnimationValueView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? AnimationValueNode) ?? AnimationValueNode()
        var c = c
        if let last = n.lastValue as? V, last != value { c.animation = animation }
        n.lastValue = value
        n.setChild(0, content, c)
        return n
    }
}

final class AnimationValueNode: PassthroughNode {
    var lastValue: Any?
}
