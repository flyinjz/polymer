// Colour. Stored as sRGB-encoded components (what designers write).
// Rendering blends in sRGB-encoded values, as CoreGraphics and browsers do;
// `linear` gives linear light where it is needed (luminance).

public struct Color: Hashable, Sendable, CustomStringConvertible {
    /// sRGB-encoded components, 0...1.
    public var red: Double, green: Double, blue: Double, opacity: Double

    @inlinable public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    @inlinable public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }
    /// `0xRRGGBB`.
    @inlinable public init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    public static let clear = Color(white: 0, opacity: 0)
    public static let black = Color(white: 0)
    public static let white = Color(white: 1)

    @inlinable public func opacity(_ o: Double) -> Color { Color(red: red, green: green, blue: blue, opacity: opacity * o) }

    /// Linear-light, straight (not premultiplied) alpha.
    @inlinable public var linear: LinearColor {
        LinearColor(r: Float(SRGB.decode(red)), g: Float(SRGB.decode(green)),
                    b: Float(SRGB.decode(blue)), a: Float(opacity))
    }

    public var description: String {
        func h(_ v: Double) -> String {
            let n = Int((min(max(v, 0), 1) * 255).rounded())
            let s = String(n, radix: 16, uppercase: true)
            return n < 16 ? "0" + s : s
        }
        return "#" + h(red) + h(green) + h(blue) + (opacity < 1 ? h(opacity) : "")
    }
}

/// Linear-light colour, straight alpha, Float for rendering.
public struct LinearColor: Hashable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    @inlinable public init(r: Float, g: Float, b: Float, a: Float) { self.r = r; self.g = g; self.b = b; self.a = a }
}

/// The sRGB transfer function (IEC 61966-2-1), exact.
public enum SRGB {
    @inlinable public static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow(base: (v + 0.055) / 1.055, 2.4)
    }
    @inlinable public static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(base: v, 1 / 2.4) - 0.055
    }
    /// 8-bit sRGB to linear.
    public static let decode8: [Float] = (0..<256).map { Float(decode(Double($0) / 255)) }

    /// Linear to 8-bit sRGB, rounded. Table of 4096 entries plus interpolation-free lookup.
    @inlinable public static func encode8(_ v: Float) -> UInt8 {
        let i = Int(min(max(v, 0), 1) * 4095 + 0.5)
        return encodeTable[i]
    }
    public static let encodeTable: [UInt8] = (0..<4096).map {
        UInt8(min(max(encode(Double($0) / 4095) * 255 + 0.5, 0), 255))
    }
}

/// x^y for x > 0 without Foundation: exp(y * ln x).
@inlinable public func pow(base x: Double, _ y: Double) -> Double {
    if x <= 0 { return 0 }
    return Math.exp(y * Math.log(x))
}

/// Elementary functions in pure Swift, so results are identical on every OS.
public enum Math {
    /// Natural logarithm, accurate to about 1 ulp for positive finite x.
    @inlinable public static func log(_ x: Double) -> Double {
        if x.isNaN || x < 0 { return .nan }
        if x == 0 { return -.infinity }
        if x.isInfinite { return x }
        // x = m * 2^e with m in [sqrt(1/2), sqrt(2)).
        var e = Double(x.exponent)
        var m = x.significand        // [1, 2)
        if m > 1.4142135623730951 { m /= 2; e += 1 }
        // log(m) = 2 atanh(s), s = (m - 1) / (m + 1), |s| < 0.1716.
        let s = (m - 1) / (m + 1)
        let s2 = s * s
        var term = s, sum = 0.0
        var k = 1.0
        while true {
            let next = sum + term / k
            if next == sum { break }
            sum = next
            term *= s2
            k += 2
        }
        return 2 * sum + e * 0.6931471805599453
    }

    /// e^x.
    @inlinable public static func exp(_ x: Double) -> Double {
        if x.isNaN { return x }
        if x > 709.78 { return .infinity }
        if x < -745.2 { return 0 }
        // x = k ln2 + r, |r| <= ln2/2.
        let k = (x / 0.6931471805599453).rounded()
        let r = (x - k * 6.93147180369123816490e-01) - k * 1.90821492927058770002e-10   // fdlibm split: k * hi is exact
        var term = 1.0, sum = 1.0, n = 1.0
        while true {
            term *= r / n
            let next = sum + term
            if next == sum { break }
            sum = next
            n += 1
        }
        return Double(sign: .plus, exponent: Int(k), significand: sum)
    }

    /// Sine, pure Swift, accurate to ~1e-15 and identical on every OS.
    @inlinable public static func sin(_ x: Double) -> Double {
        if !x.isFinite { return .nan }
        let twoOverPi = 0.63661977236758134308
        let q = (x * twoOverPi).rounded()
        // Range reduction: r = x - q * (pi/2) using a hi+lo split of pi/2.
        let r = (x - q * 1.57079632673412561417e+00) - q * 6.07710050650619224932e-11
        let quad = Int(q.truncatingRemainder(dividingBy: 4)) & 3
        switch quad {
        case 0: return sinReduced(r)
        case 1: return cosReduced(r)
        case 2: return -sinReduced(r)
        default: return -cosReduced(r)
        }
    }

    /// Cosine, pure Swift, accurate to ~1e-15 and identical on every OS.
    @inlinable public static func cos(_ x: Double) -> Double {
        if !x.isFinite { return .nan }
        let twoOverPi = 0.63661977236758134308
        let q = (x * twoOverPi).rounded()
        let r = (x - q * 1.57079632673412561417e+00) - q * 6.07710050650619224932e-11
        let quad = Int(q.truncatingRemainder(dividingBy: 4)) & 3
        switch quad {
        case 0: return cosReduced(r)
        case 1: return -sinReduced(r)
        case 2: return -cosReduced(r)
        default: return sinReduced(r)
        }
    }

    @inlinable static func sinReduced(_ r: Double) -> Double {
        let r2 = r * r
        var term = r, sum = r, n = 1.0
        while true {
            term = -term * r2 / ((2 * n) * (2 * n + 1))
            let next = sum + term
            if next == sum { break }
            sum = next
            n += 1
        }
        return sum
    }

    @inlinable static func cosReduced(_ r: Double) -> Double {
        let r2 = r * r
        var term = 1.0, sum = 1.0, n = 1.0
        while true {
            term = -term * r2 / ((2 * n - 1) * (2 * n))
            let next = sum + term
            if next == sum { break }
            sum = next
            n += 1
        }
        return sum
    }
}
