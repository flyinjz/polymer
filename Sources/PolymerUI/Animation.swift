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
        bezierCoord(y1, y2, bezierParameter(x1, x2, at: x))
    }

    /// The curve's slope (dy/dx) where its x is `x`.
    static func bezierSlope(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, at x: Double) -> Double {
        let s = bezierParameter(x1, x2, at: min(max(x, 0), 1))
        let dx = bezierDerivative(x1, x2, s), dy = bezierDerivative(y1, y2, s)
        return abs(dx) < 1e-12 ? 0 : dy / dx
    }

    private static func bezierCoord(_ a: Double, _ b: Double, _ s: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
    private static func bezierDerivative(_ a: Double, _ b: Double, _ s: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
    }

    /// The curve parameter where its x is `x`.
    private static func bezierParameter(_ x1: Double, _ x2: Double, at x: Double) -> Double {
        let coord = bezierCoord, slope = bezierDerivative
        var s = x
        for _ in 0..<8 {
            let e = coord(x1, x2, s) - x
            if abs(e) < 1e-9 { return s }
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
        return s
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

/// Values that can move smoothly from one to another: a vector space
/// (adding and scaling), so velocities can be carried from one animation
/// into the next. SwiftUI's `VectorArithmetic`, internal for now.
protocol Interpolatable: Equatable {
    func adding(_ other: Self) -> Self
    func scaled(by k: Double) -> Self
    /// The sum of the squared components, for measuring how far there is to go.
    var magnitudeSquared: Double { get }
    /// The value as it can be shown (widths not negative, colours in range).
    var shown: Self { get }
}

extension Interpolatable {
    func subtracting(_ other: Self) -> Self { adding(other.scaled(by: -1)) }
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self { a.adding(b.subtracting(a).scaled(by: t)).shown }
}

extension Double: Interpolatable {
    func adding(_ o: Double) -> Double { self + o }
    func scaled(by k: Double) -> Double { self * k }
    var magnitudeSquared: Double { self * self }
    var shown: Double { self }
}

extension Point: Interpolatable {
    func adding(_ o: Point) -> Point { Point(x: x + o.x, y: y + o.y) }
    func scaled(by k: Double) -> Point { Point(x: x * k, y: y * k) }
    var magnitudeSquared: Double { x * x + y * y }
    var shown: Point { self }
}

extension Rect: Interpolatable {
    func adding(_ o: Rect) -> Rect { Rect(x: minX + o.minX, y: minY + o.minY, width: width + o.width, height: height + o.height) }
    func scaled(by k: Double) -> Rect { Rect(x: minX * k, y: minY * k, width: width * k, height: height * k) }
    var magnitudeSquared: Double { minX * minX + minY * minY + width * width + height * height }
    var shown: Rect { Rect(x: minX, y: minY, width: max(0, width), height: max(0, height)) }
}

/// A colour's components without clamping: a colour on its way somewhere
/// (a spring may carry it past the end) or the difference of two colours.
struct ColorVector: Interpolatable {
    var r, g, b, a: Double
    init(_ c: Color) { r = c.red; g = c.green; b = c.blue; a = c.opacity }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    func adding(_ o: ColorVector) -> ColorVector { ColorVector(r: r + o.r, g: g + o.g, b: b + o.b, a: a + o.a) }
    func scaled(by k: Double) -> ColorVector { ColorVector(r: r * k, g: g * k, b: b * k, a: a * k) }
    var magnitudeSquared: Double { r * r + g * g + b * b + a * a }
    var shown: ColorVector { self }
    /// In range, as the canvas blends (sRGB-encoded values).
    var color: Color {
        func c(_ v: Double) -> Double { min(max(v, 0), 1) }
        return Color(red: c(r), green: c(g), blue: c(b), opacity: c(a))
    }
}

/// A value that, when changed with an animation, moves from what is shown
/// to the new value. A spring carries the speed the value had when it was
/// interrupted, so a change in mid-flight bends the motion instead of
/// stopping it (as in SwiftUI); a timing curve starts again from the shown
/// value at rest.
struct Animated<T: Interpolatable> {
    private(set) var target: T
    private var from: T
    /// Velocity at the start, per second (springs only).
    private var velocity: T
    private var start = 0.0
    /// Seconds from the start until the value has arrived.
    private var length = 0.0
    private var animation: Animation?

    init(_ value: T) { target = value; from = value; velocity = value.scaled(by: 0) }

    /// Changes the value; with an animation it starts from the value (and,
    /// for a spring, the speed) shown at `now`. Returns true when an animation started.
    mutating func set(_ value: T, animation: Animation?, now: Double) -> Bool {
        guard value != target else { return false }
        if let animation, animation.duration > 0 {
            let shownNow = raw(at: now)
            let speed = self.speed(at: now)
            from = shownNow
            start = now
            self.animation = animation
            target = value
            if case .spring = animation.curve, speed.magnitudeSquared > 0 {
                velocity = speed
                length = Animated.settleTime(animation, displacement: from.subtracting(target), velocity: speed)
            } else {
                velocity = value.scaled(by: 0)
                length = animation.duration
            }
            return true
        }
        self.animation = nil
        target = value
        return false
    }

    /// The value shown at `now`.
    func value(at now: Double) -> T { raw(at: now).shown }

    func isRunning(at now: Double) -> Bool { animation != nil && now - start < length }

    /// The value at `now` before it is made showable.
    private func raw(at now: Double) -> T {
        guard let a = animation, now - start < length else { return target }
        let t = now - start
        switch a.curve {
        case .bezier:
            return from.adding(target.subtracting(from).scaled(by: a.progress(t)))
        case .spring(let response, let z):
            let s = Animated.spring(response, z, t)
            return target.adding(from.subtracting(target).scaled(by: s.f)).adding(velocity.scaled(by: s.g))
        }
    }

    /// How fast the value is changing at `now`, per second.
    func speed(at now: Double) -> T {
        guard let a = animation, now - start < length else { return target.scaled(by: 0) }
        let t = now - start
        switch a.curve {
        case .bezier(let x1, let y1, let x2, let y2, let d):
            return target.subtracting(from).scaled(by: Animation.bezierSlope(x1, y1, x2, y2, at: t / d) / d)
        case .spring(let response, let z):
            let s = Animated.spring(response, z, t)
            return from.subtracting(target).scaled(by: s.df).adding(velocity.scaled(by: s.dg))
        }
    }

    /// A damped spring's displacement at `t` is `x0 * f + v0 * g`, its speed `x0 * df + v0 * dg`.
    static func spring(_ response: Double, _ z: Double, _ t: Double) -> (f: Double, g: Double, df: Double, dg: Double) {
        let w = 2 * Double.pi / response
        if z >= 1 {
            let e = Math.exp(-w * t)
            return (e * (1 + w * t), t * e, -w * w * t * e, e * (1 - w * t))
        }
        let a = z * w, b = w * (1 - z * z).squareRoot()
        let e = Math.exp(-a * t), c = Math.cos(b * t), s = Math.sin(b * t)
        return (e * (c + a / b * s), e * s / b, -e * s * w * w / b, e * (c - a * s / b))
    }

    /// How long a spring starting with this displacement and velocity takes to
    /// come within 0.1% of its size and stay there (`duration` when it starts at rest).
    static func settleTime(_ animation: Animation, displacement x0: T, velocity v0: T) -> Double {
        guard case .spring(let response, let z) = animation.curve else { return animation.duration }
        let w = 2 * Double.pi / response
        let x = x0.magnitudeSquared.squareRoot(), v = v0.magnitudeSquared.squareRoot()
        let threshold = 0.001 * (x + v / w)
        guard threshold > 0 else { return 0 }
        if z >= 1 {
            // |x(t)| <= e^(-wt) (|x0| + |v0 + w x0| t): where that bound falls under the threshold.
            let a0 = x, b0 = v0.adding(x0.scaled(by: w)).magnitudeSquared.squareRoot()
            func bound(_ t: Double) -> Double { Math.exp(-w * t) * (a0 + b0 * t) }
            var lo = 0.0, hi = 1 / w
            while bound(hi) > threshold { lo = hi; hi *= 2 }
            for _ in 0..<50 { let m = (lo + hi) / 2; if bound(m) > threshold { lo = m } else { hi = m } }
            return hi
        }
        let a = z * w, b = w * (1 - z * z).squareRoot()
        let envelope = (x * x + v0.adding(x0.scaled(by: a)).magnitudeSquared / (b * b)).squareRoot()
        return max(0, Math.log(envelope / threshold) / a)
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
