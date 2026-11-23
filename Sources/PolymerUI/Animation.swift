// Deterministic animations and scroll physics.
// All curves (cubic Bézier and analytical damped spring) use pure Swift math
// so frame output is identical on every OS at any refresh rate.
import PolymerBase
import Synchronization

/// An animation curve with optional delay and speed multiplier (SwiftUI's `Animation`).
public struct Animation: Hashable, Sendable {
    public enum Curve: Hashable, Sendable {
        case linear(duration: Double)
        case timingCurve(c0x: Double, c0y: Double, c1x: Double, c1y: Double, duration: Double)
        case spring(response: Double, dampingFraction: Double)
    }

    public var curve: Curve
    public var delay: Double = 0
    public var speed: Double = 1

    public init(_ curve: Curve, delay: Double = 0, speed: Double = 1) {
        self.curve = curve; self.delay = delay; self.speed = speed
    }

    public static let `default` = Animation.easeInOut(duration: 0.25)

    public static func linear(duration: Double = 0.35) -> Animation {
        Animation(.linear(duration: max(0, duration)))
    }
    public static func easeIn(duration: Double = 0.35) -> Animation {
        timingCurve(0.42, 0, 1, 1, duration: duration)
    }
    public static func easeOut(duration: Double = 0.35) -> Animation {
        timingCurve(0, 0, 0.58, 1, duration: duration)
    }
    public static func easeInOut(duration: Double = 0.35) -> Animation {
        timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }
    public static func timingCurve(_ c0x: Double, _ c0y: Double, _ c1x: Double, _ c1y: Double, duration: Double = 0.35) -> Animation {
        Animation(.timingCurve(c0x: c0x, c0y: c0y, c1x: c1x, c1y: c1y, duration: max(0, duration)))
    }
    public static func spring(response: Double = 0.55, dampingFraction: Double = 0.825) -> Animation {
        Animation(.spring(response: max(1e-4, response), dampingFraction: max(0.05, dampingFraction)))
    }
    public static func snappy(duration: Double = 0.28) -> Animation {
        .spring(response: duration, dampingFraction: 0.92)
    }
    public static func smooth(duration: Double = 0.35) -> Animation {
        .spring(response: duration, dampingFraction: 1.0)
    }

    public func delay(_ seconds: Double) -> Animation {
        var copy = self; copy.delay += max(0, seconds); return copy
    }
    public func speed(_ multiplier: Double) -> Animation {
        var copy = self; copy.speed *= max(1e-6, multiplier); return copy
    }

    /// Evaluates the animation at `elapsed` seconds since it started.
    /// Returns progress (0 at start, 1 at end; springs may briefly overshoot)
    /// and whether the animation has settled.
    public func evaluate(at elapsed: Double) -> (progress: Double, finished: Bool) {
        let t = (elapsed - delay) * speed
        if t <= 0 { return (0, false) }
        switch curve {
        case .linear(let duration):
            if duration <= 0 || t >= duration { return (1, true) }
            return (t / duration, false)
        case .timingCurve(let c0x, let c0y, let c1x, let c1y, let duration):
            if duration <= 0 || t >= duration { return (1, true) }
            let x = t / duration
            return (Self.solveBezier(x: x, c0x: c0x, c0y: c0y, c1x: c1x, c1y: c1y), false)
        case .spring(let response, let damping):
            return Self.evaluateSpring(t: t, response: response, damping: damping)
        }
    }

    private static func solveBezier(x: Double, c0x: Double, c0y: Double, c1x: Double, c1y: Double) -> Double {
        let ax = 3 * c0x - 3 * c1x + 1, bx = 3 * c1x - 6 * c0x, cx = 3 * c0x
        let ay = 3 * c0y - 3 * c1y + 1, by = 3 * c1y - 6 * c0y, cy = 3 * c0y
        @inline(__always) func sampleX(_ u: Double) -> Double { ((ax * u + bx) * u + cx) * u }
        @inline(__always) func sampleDX(_ u: Double) -> Double { (3 * ax * u + 2 * bx) * u + cx }
        @inline(__always) func sampleY(_ u: Double) -> Double { ((ay * u + by) * u + cy) * u }

        var u = x
        for _ in 0..<8 {
            let err = sampleX(u) - x
            if abs(err) < 1e-7 { return sampleY(u) }
            let d = sampleDX(u)
            if abs(d) < 1e-6 { break }
            u -= err / d
            if u < 0 || u > 1 { break }
        }
        var lo = 0.0, hi = 1.0
        u = x
        for _ in 0..<24 {
            let v = sampleX(u)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = u } else { hi = u }
            u = (lo + hi) * 0.5
        }
        return sampleY(u)
    }

    private static func evaluateSpring(t: Double, response: Double, damping: Double) -> (Double, Bool) {
        let omega0 = 2 * Double.pi / response
        let zeta = damping
        if abs(zeta - 1) < 1e-4 {
            let decay = Math.exp(-omega0 * t)
            if decay * (1 + omega0 * t) < 1e-4 { return (1, true) }
            return (1 - decay * (1 + omega0 * t), false)
        } else if zeta < 1 {
            let decay = Math.exp(-zeta * omega0 * t)
            if decay < 1e-4 { return (1, true) }
            let omegaD = omega0 * (1 - zeta * zeta).squareRoot()
            let v = 1 - decay * (Math.cos(omegaD * t) + (zeta * omega0 / omegaD) * Math.sin(omegaD * t))
            return (v, false)
        } else {
            let s = omega0 * (zeta * zeta - 1).squareRoot()
            let r1 = -zeta * omega0 + s
            let r2 = -zeta * omega0 - s
            let e1 = Math.exp(r1 * t)
            let e2 = Math.exp(r2 * t)
            if e1 < 1e-4 { return (1, true) }
            let v = 1 - (r2 * e1 - r1 * e2) / (r2 - r1)
            return (v, false)
        }
    }
}

/// Active animation transaction captured synchronously when state mutates inside `withAnimation`.
enum AnimationTransaction {
    private static let active = Mutex<Animation?>(nil)
    static var current: Animation? { active.withLock { $0 } }
    static func swap(_ next: Animation?) -> Animation? {
        active.withLock { cur in
            let prev = cur
            cur = next
            return prev
        }
    }
}

/// Runs `body` with `animation` attached to every state change it makes (SwiftUI's `withAnimation`).
@MainActor
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    let previous = AnimationTransaction.swap(animation)
    defer { _ = AnimationTransaction.swap(previous) }
    return try body()
}

/// A scalar or point being interpolated over time on a node.
struct AnimatedDouble {
    var from: Double
    var target: Double
    var current: Double
    var animation: Animation?
    var elapsed: Double = 0

    init(_ value: Double) { from = value; target = value; current = value }

    var isActive: Bool { animation != nil }

    mutating func set(_ newTarget: Double, animation anim: Animation?) -> Bool {
        if newTarget == target { return false }
        if let anim {
            from = current
            target = newTarget
            animation = anim
            elapsed = 0
            return true
        } else {
            from = newTarget
            target = newTarget
            current = newTarget
            animation = nil
            elapsed = 0
            return false
        }
    }

    mutating func step(_ dt: Double) -> Bool {
        guard let anim = animation else { return false }
        elapsed += max(0, dt)
        let (p, done) = anim.evaluate(at: elapsed)
        if done {
            current = target
            animation = nil
            return false
        }
        current = from + (target - from) * p
        return true
    }
}

struct AnimatedPoint {
    var from: Point
    var target: Point
    var current: Point
    var animation: Animation?
    var elapsed: Double = 0

    init(_ value: Point) { from = value; target = value; current = value }

    var isActive: Bool { animation != nil }

    mutating func set(_ newTarget: Point, animation anim: Animation?) -> Bool {
        if newTarget == target { return false }
        if let anim {
            from = current
            target = newTarget
            animation = anim
            elapsed = 0
            return true
        } else {
            from = newTarget
            target = newTarget
            current = newTarget
            animation = nil
            elapsed = 0
            return false
        }
    }

    mutating func step(_ dt: Double) -> Bool {
        guard let anim = animation else { return false }
        elapsed += max(0, dt)
        let (p, done) = anim.evaluate(at: elapsed)
        if done {
            current = target
            animation = nil
            return false
        }
        current = Point(x: from.x + (target.x - from.x) * p, y: from.y + (target.y - from.y) * p)
        return true
    }
}

/// Implemented by nodes whose properties animate across `ViewTree.tick(_:)`.
@MainActor
protocol AnimatableTicking: AnyObject {
    var isMounted: Bool { get }
    var isAnimating: Bool { get }
    /// Advances by `dt` seconds. Returns true while still animating.
    func tick(_ dt: Double) -> Bool
}

struct WeakAnimatable { weak var node: (any AnimatableTicking)? }

/// Exponential friction deceleration for inertial scroll flings.
public struct ScrollPhysics: Hashable, Sendable {
    /// Decay rate in 1/seconds (higher stops sooner).
    public var friction: Double
    /// Velocity threshold in points/second below which scrolling stops.
    public var stopVelocity: Double

    public static let standard = ScrollPhysics(friction: 4.5, stopVelocity: 5.0)

    public init(friction: Double = 4.5, stopVelocity: Double = 5.0) {
        self.friction = max(0.1, friction); self.stopVelocity = max(0.1, stopVelocity)
    }

    /// Advances `(vx, vy)` by `dt` seconds; returns displacement `(dx, dy)` in
    /// points, new velocity, and whether the fling is still moving.
    public func step(vx: Double, vy: Double, dt: Double) -> (dx: Double, dy: Double, vx: Double, vy: Double, active: Bool) {
        guard dt > 0 else { return (0, 0, vx, vy, (vx * vx + vy * vy).squareRoot() >= stopVelocity) }
        let decay = Math.exp(-friction * dt)
        let factor = (1 - decay) / friction
        let dx = vx * factor, dy = vy * factor
        let nvx = vx * decay, nvy = vy * decay
        let speed = (nvx * nvx + nvy * nvy).squareRoot()
        if speed < stopVelocity { return (dx, dy, 0, 0, false) }
        return (dx, dy, nvx, nvy, true)
    }
}

// MARK: `.animation(_:value:)` modifier

extension View {
    /// Applies `animation` to changes inside this view whenever `value` changes.
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        AnimationValueView(content: self, animation: animation, value: value)
    }
}

struct AnimationValueView<Content: View, V: Equatable>: View, PrimitiveView {
    let content: Content
    let animation: Animation?
    let value: V

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? AnimationValueNode<V>) ?? AnimationValueNode<V>()
        var c = c
        if let prev = n.previous, prev != value { c.animation = animation }
        n.previous = value
        n.setChild(0, content, c)
        return n
    }
}

final class AnimationValueNode<V: Equatable>: PassthroughNode {
    var previous: V?
}
