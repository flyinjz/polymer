// The parametric EQ's data: bands, profiles, the live state, its magnitude
// response and Equalizer APO text interchange. Ported from Meimei's
// Core/EqualizerData.swift; same JSON keys and defaults. Differences:
//  - ids are UUID strings (canonical uppercase), not Foundation UUIDs.
//  - built-in profile bands have fixed ids (Meimei made new random ones
//    each launch), so the built-ins are identical on every run and OS.
//  - functions that made a random id take an `id:` to inject one.
import PolymerBase

// MARK: - Bands

/// What one EQ band does to the signal.
public enum EQFilterType: String, CaseIterable, Sendable {
    case bell, lowShelf, highShelf, lowCut, highCut, notch, bandPass

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bell: return "Bell"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowCut: return "Low Cut"
        case .highCut: return "High Cut"
        case .notch: return "Notch"
        case .bandPass: return "Band Pass"
        }
    }

    /// Meimei's SF Symbol name, kept as data.
    public var symbol: String {
        switch self {
        case .bell: return "chevron.up"
        case .lowShelf: return "arrow.down.left"
        case .highShelf: return "arrow.up.right"
        case .lowCut: return "arrow.up.forward"
        case .highCut: return "arrow.down.forward"
        case .notch: return "chevron.down"
        case .bandPass: return "dot.radiowaves.up.forward"
        }
    }

    public var hasGain: Bool { self == .bell || self == .lowShelf || self == .highShelf }
    public var hasQ: Bool { self == .bell || self == .notch || self == .bandPass }
    public var hasSlope: Bool { self == .lowCut || self == .highCut }
}

/// One band of the parametric EQ.
public struct EQBand: Hashable, Sendable, Identifiable {
    public var id: String
    public var type: EQFilterType = .bell
    /// Center or corner frequency, in Hz.
    public var frequency: Double
    public var gain: Double = 0
    public var q: Double = 0.71
    /// Roll-off of the cut filters, in dB/octave (a multiple of 12).
    public var slope: Int = 12
    public var enabled = true

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let qRange: ClosedRange<Double> = 0.1...18
    public static let slopes = [12, 24, 36, 48]

    public init(id: String = UUIDString.random(), type: EQFilterType = .bell, frequency: Double, gain: Double = 0,
                q: Double = 0.71, slope: Int = 12, enabled: Bool = true) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.slope = slope
        self.enabled = enabled
    }

    /// Bandwidth in octaves.
    public var octaves: Double { 2 * EQMath.asinh(1 / (2 * q)) / EQMath.ln2 }

    public static func q(fromOctaves bw: Double) -> Double {
        1 / (2 * EQMath.sinh(EQMath.ln2 / 2 * bw))
    }

    /// Engine slots this band needs: cuts cascade one 12 dB/oct filter per step.
    public var slotCount: Int { type.hasSlope ? max(1, slope / 12) : 1 }

    public func clamped(gainLimit: Double) -> EQBand {
        var b = self
        b.frequency = min(Self.frequencyRange.upperBound, max(Self.frequencyRange.lowerBound, frequency))
        b.gain = min(gainLimit, max(-gainLimit, gain))
        b.q = min(Self.qRange.upperBound, max(Self.qRange.lowerBound, q))
        b.slope = Self.slopes.min { abs($0 - slope) < abs($1 - slope) } ?? 12
        return b
    }
}

extension EQBand {
    /// Strict, as Meimei's synthesized decoder: every key is required.
    public init?(json j: JSON) {
        guard let id = j["id"]?.string.flatMap(UUIDString.canonical),
              let type = j["type"]?.string.flatMap(EQFilterType.init(rawValue:)),
              let frequency = j["frequency"]?.double, let gain = j["gain"]?.double, let q = j["q"]?.double,
              let slope = j["slope"]?.int, let enabled = j["enabled"]?.bool
        else { return nil }
        self.init(id: id, type: type, frequency: frequency, gain: gain, q: q, slope: slope, enabled: enabled)
    }

    public var json: JSON {
        .object([
            "id": .string(id), "type": .raw(type), "frequency": .number(frequency), "gain": .number(gain),
            "q": .number(q), "slope": .number(Double(slope)), "enabled": .bool(enabled),
        ])
    }

    /// An array of bands; one unreadable band and the whole list is nil.
    public static func list(json: JSON) -> [EQBand]? {
        guard let items = json.array else { return nil }
        var out: [EQBand] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let b = EQBand(json: item) else { return nil }
            out.append(b)
        }
        return out
    }
}

/// Vertical scale of the EQ editor; also the gain limit. Stored as its number.
public enum EQGainRange: Double, CaseIterable, Sendable {
    case six = 6, twelve = 12, eighteen = 18, twentyFour = 24, thirty = 30

    public var id: Double { rawValue }
    public var label: String { "±\(Int(rawValue)) dB" }
    public var closed: ClosedRange<Double> { -rawValue...rawValue }
}

// MARK: - Profiles

/// A named EQ curve: a built-in starting point (read-only) or one the user saved.
public struct EQProfile: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bands: [EQBand]
    public var preampGain: Double
    public var isBuiltIn: Bool

    public init(id: String = UUIDString.random(), name: String, bands: [EQBand], preampGain: Double = 0,
                isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.bands = bands
        self.preampGain = preampGain
        self.isBuiltIn = isBuiltIn
    }

    /// Center frequencies of the classic ten-band graphic EQ.
    public static let graphicFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Ten bells at the graphic-EQ frequencies.
    public static func graphic(gains: [Double], bypass: [Bool] = [], octaves: Double = 1) -> [EQBand] {
        graphicFrequencies.enumerated().map { i, f in
            EQBand(frequency: f, gain: gains.indices.contains(i) ? gains[i] : 0, q: EQBand.q(fromOctaves: octaves),
                   enabled: !(bypass.indices.contains(i) && bypass[i]))
        }
    }
}

extension EQProfile {
    /// As Meimei's decoder: `id` and `name` required; `preampGain` and
    /// `isBuiltIn` default when missing or null; `bands`, or else the
    /// 10-band graphic EQ's `bandGains` / `bandBypass` / `bandwidth`.
    /// A present value of the wrong type fails the whole profile.
    public init?(json j: JSON) {
        guard let o = j.object, let id = o["id"]?.string.flatMap(UUIDString.canonical),
              let name = o["name"]?.string else { return nil }
        func present(_ k: String) -> JSON? {
            guard let v = o[k], !v.isNull else { return nil }
            return v
        }
        var preamp = 0.0, builtIn = false
        if let v = present("preampGain") { guard let d = v.double else { return nil }; preamp = d }
        if let v = present("isBuiltIn") { guard let b = v.bool else { return nil }; builtIn = b }
        let bands: [EQBand]
        if let v = present("bands") {
            guard let b = EQBand.list(json: v) else { return nil }
            bands = b
        } else {
            var gains: [Double] = [], bypass: [Bool] = [], octaves = 1.0
            if let v = present("bandGains") { guard let g = EQMath.doubles(v) else { return nil }; gains = g }
            if let v = present("bandBypass") { guard let b = EQMath.bools(v) else { return nil }; bypass = b }
            if let v = present("bandwidth") { guard let d = v.double else { return nil }; octaves = d }
            bands = EQProfile.graphic(gains: gains, bypass: bypass, octaves: octaves)
        }
        self.init(id: id, name: name, bands: bands, preampGain: preamp, isBuiltIn: builtIn)
    }

    /// Meimei's keys: id, name, bands, preampGain, isBuiltIn.
    public var json: JSON {
        .object([
            "id": .string(id), "name": .string(name), "bands": .array(bands.map(\.json)),
            "preampGain": .number(preampGain), "isBuiltIn": .bool(isBuiltIn),
        ])
    }

    /// A stored profile list; one unreadable profile and the whole list is nil.
    public static func list(json: JSON) -> [EQProfile]? {
        guard let items = json.array else { return nil }
        var out: [EQProfile] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let p = EQProfile(json: item) else { return nil }
            out.append(p)
        }
        return out
    }

    public static func json(_ list: [EQProfile]) -> JSON { .array(list.map(\.json)) }
}

extension EQProfile {
    public static let flatID = "9E5B0000-0000-4000-8000-000000000001"

    private static func builtIn(_ n: Int, _ name: String, preamp: Double = 0, _ bands: [EQBand]) -> EQProfile {
        var bands = bands
        for i in bands.indices { bands[i].id = "9E5B0000-0000-4000-8001-" + TextTools.zeroPadded(n * 100 + i + 1, 12) }
        return EQProfile(id: "9E5B0000-0000-4000-8000-" + TextTools.zeroPadded(n, 12),
                         name: name, bands: bands, preampGain: preamp, isBuiltIn: true)
    }

    public static let builtIns: [EQProfile] = [
        builtIn(1, "Flat", []),
        builtIn(2, "Bass Boost", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 105, gain: 6),
            EQBand(frequency: 60, gain: 1.5, q: 1),
        ]),
        builtIn(3, "Treble Boost", preamp: -5, [EQBand(type: .highShelf, frequency: 4500, gain: 5.5)]),
        builtIn(4, "Vocal", preamp: -3, [
            EQBand(type: .lowCut, frequency: 90, slope: 12),
            EQBand(frequency: 250, gain: -2, q: 1.2),
            EQBand(frequency: 2800, gain: 3, q: 0.9),
            EQBand(type: .highShelf, frequency: 9000, gain: -1.5),
        ]),
        builtIn(5, "Rock", preamp: -4, [
            EQBand(type: .lowShelf, frequency: 90, gain: 4),
            EQBand(frequency: 700, gain: -2, q: 0.8),
            EQBand(type: .highShelf, frequency: 5000, gain: 3.5),
        ]),
        builtIn(6, "Pop", preamp: -3, [
            EQBand(frequency: 120, gain: 2, q: 0.9),
            EQBand(frequency: 400, gain: 2.5, q: 0.8),
            EQBand(type: .highShelf, frequency: 8000, gain: -1),
        ]),
        builtIn(7, "Classical", preamp: -3, [
            EQBand(type: .lowShelf, frequency: 120, gain: 2.5),
            EQBand(type: .highShelf, frequency: 6000, gain: 2.5),
        ]),
        builtIn(8, "Electronic", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 80, gain: 5),
            EQBand(frequency: 500, gain: -1.5, q: 0.9),
            EQBand(type: .highShelf, frequency: 7000, gain: 4),
        ]),
        builtIn(9, "Loudness", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 100, gain: 5),
            EQBand(frequency: 3000, gain: -1, q: 0.7),
            EQBand(type: .highShelf, frequency: 10000, gain: 4),
        ]),
        builtIn(10, "Hip-Hop", preamp: -6, [
            EQBand(frequency: 55, gain: 6, q: 0.9),
            EQBand(frequency: 300, gain: -2, q: 1),
            EQBand(frequency: 3500, gain: 1.5, q: 1),
        ]),
        builtIn(11, "Acoustic", preamp: -2, [
            EQBand(frequency: 200, gain: 1.5, q: 0.8),
            EQBand(frequency: 2500, gain: 2, q: 0.9),
            EQBand(type: .highShelf, frequency: 9000, gain: 1.5),
        ]),
        builtIn(12, "Spoken Word", preamp: -3, [
            EQBand(type: .lowCut, frequency: 100, slope: 24),
            EQBand(frequency: 3000, gain: 3, q: 0.8),
            EQBand(type: .highCut, frequency: 12000, slope: 12),
        ]),
        builtIn(13, "Late Night", preamp: -1, [
            EQBand(type: .lowShelf, frequency: 120, gain: -4),
            EQBand(frequency: 2500, gain: 1.5, q: 0.8),
            EQBand(type: .highShelf, frequency: 7000, gain: -3),
        ]),
        builtIn(14, "Warm", preamp: -2, [
            EQBand(type: .lowShelf, frequency: 200, gain: 2),
            EQBand(type: .highShelf, frequency: 6000, gain: -2.5),
        ]),
        builtIn(15, "Bright", preamp: -3, [
            EQBand(frequency: 300, gain: -1.5, q: 0.7),
            EQBand(type: .highShelf, frequency: 3500, gain: 3),
        ]),
    ]
}

// MARK: - Live state

/// The live equalizer state, persisted as one blob.
public struct EqualizerSettingsData: LenientDecodable, Hashable {
    public var enabled = false
    /// Gain applied before the filters (headroom for boosts).
    public var preampGain: Double = 0
    public var bands: [EQBand] = []
    public var autoPreamp = false
    public var gainRange: EQGainRange = .twelve
    /// nil is stored by leaving the key out; a stored null reads back as nil.
    public var activeProfileID: String? = EQProfile.flatID
    public var showAnalyzer = true

    public init() {}

    public init(lenient f: LenientFields) {
        enabled = f.bool("enabled", enabled)
        preampGain = f.double("preampGain", preampGain)
        if let v = f["bands"], let b = EQBand.list(json: v) { bands = b }
        autoPreamp = f.bool("autoPreamp", autoPreamp)
        if let g = f["gainRange"]?.double.flatMap(EQGainRange.init(rawValue:)) { gainRange = g }
        if let v = f["activeProfileID"] {
            if v.isNull { activeProfileID = nil }
            else if let id = v.string.flatMap(UUIDString.canonical) { activeProfileID = id }
        }
        showAnalyzer = f.bool("showAnalyzer", showAnalyzer)
    }

    public var json: JSON {
        var o: [String: JSON] = [
            "enabled": .bool(enabled), "preampGain": .number(preampGain), "bands": .array(bands.map(\.json)),
            "autoPreamp": .bool(autoPreamp), "gainRange": .number(gainRange.rawValue), "showAnalyzer": .bool(showAnalyzer),
        ]
        if let activeProfileID { o["activeProfileID"] = .string(activeProfileID) }
        return .object(o)
    }

    /// Decodes leniently, then migrates the older fixed ten-band graphic EQ
    /// (`bandGains`, optional `bandBypass` and `bandwidth`) when no `bands`
    /// key is stored: its non-flat bands become bells.
    public static func load(from bytes: [UInt8]) -> Self {
        var d = decodeLeniently(from: bytes)
        guard let o = (try? JSON.parse(bytes))?.object, o["bands"] == nil,
              let gains = o["bandGains"].flatMap(EQMath.doubles) else { return d }
        var bypass: [Bool]? = nil, octaves: Double? = nil
        if let v = o["bandBypass"], !v.isNull {
            guard let b = EQMath.bools(v) else { return d }
            bypass = b
        }
        if let v = o["bandwidth"], !v.isNull {
            guard let w = v.double else { return d }
            octaves = w
        }
        d.bands = EQProfile.graphic(gains: gains, bypass: bypass ?? [], octaves: octaves ?? 1)
            .filter { abs($0.gain) > 0.001 }
        return d
    }
}

/// Engine slots available to bands (cut filters take one per 12 dB/oct).
public let eqEngineSlots = 48

/// Magnitude response of the EQ: RBJ biquads matching the filters the
/// engine runs, evaluated at 48 kHz.
public enum EqualizerResponse {
    public static let sampleRate = 48_000.0

    public static func gain(atHz hz: Double, data: EqualizerSettingsData) -> Double {
        data.bands.reduce(data.preampGain) { $0 + ($1.enabled ? gain(atHz: hz, band: $1) : 0) }
    }

    public static func gain(atHz hz: Double, band: EQBand) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let f0 = min(band.frequency, sampleRate * 0.49)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = Math.cos(w0), sw = Math.sin(w0)
        let a = pow(base: 10, band.gain / 40)
        let c: (Double, Double, Double, Double, Double, Double)
        var repeats = 1.0
        switch band.type {
        case .bell:
            guard abs(band.gain) > 0.001 else { return 0 }
            let alpha = sw / (2 * band.q)
            c = (1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a)
        case .lowShelf, .highShelf:
            guard abs(band.gain) > 0.001 else { return 0 }
            let alpha = sw / 2 * 2.0.squareRoot()
            let s = 2 * a.squareRoot() * alpha
            if band.type == .lowShelf {
                c = (a * ((a + 1) - (a - 1) * cw + s), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - s),
                     (a + 1) + (a - 1) * cw + s, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - s)
            } else {
                c = (a * ((a + 1) + (a - 1) * cw + s), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - s),
                     (a + 1) - (a - 1) * cw + s, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - s)
            }
        case .lowCut, .highCut:
            let alpha = sw / (2 * 0.5.squareRoot())
            repeats = Double(band.slotCount)
            if band.type == .lowCut {
                c = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
            } else {
                c = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
            }
        case .notch:
            let alpha = sw / (2 * band.q)
            c = (1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha)
        case .bandPass:
            let alpha = sw / (2 * band.q)
            c = (alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha)
        }
        let db = 20 * EQMath.log10(magnitude(c.0, c.1, c.2, w) / magnitude(c.3, c.4, c.5, w))
        return max(-120, db * repeats)
    }

    private static func magnitude(_ c0: Double, _ c1: Double, _ c2: Double, _ w: Double) -> Double {
        let re = c0 + c1 * Math.cos(w) + c2 * Math.cos(2 * w)
        let im = -(c1 * Math.sin(w) + c2 * Math.sin(2 * w))
        return max(1e-12, (re * re + im * im).squareRoot())
    }
}

// MARK: - Interchange

/// Reads and writes Equalizer APO / AutoEQ "ParametricEQ.txt" files, the
/// format headphone correction presets are published in.
public enum ParametricEQText {
    /// The profile in `text`, or nil if it has no filter lines this reads.
    public static func parse(_ text: String, name: String, id: String = UUIDString.random()) -> EQProfile? {
        var bands: [EQBand] = []
        var preamp = 0.0
        for raw in TextTools.components(text, separatedBy: TextTools.isNewline) {
            let line = TextTools.trimming(raw, TextTools.isWhitespace)
            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                preamp = number(after: "preamp:", in: lower) ?? 0
                continue
            }
            guard lower.hasPrefix("filter"), TextTools.contains(lower, " on ") || TextTools.contains(lower, ":on ")
            else { continue }
            let tokens = TextTools.replacing(line, ":", with: " ").split(separator: " ").map(String.init)
            guard let onIndex = tokens.firstIndex(where: { $0.uppercased() == "ON" }), onIndex + 1 < tokens.count
            else { continue }
            let kind: EQFilterType?
            switch tokens[onIndex + 1].uppercased() {
            case "PK", "PEQ", "MODAL": kind = .bell
            case "LS", "LSC", "LSQ", "LS6", "LS12": kind = .lowShelf
            case "HS", "HSC", "HSQ", "HS6", "HS12": kind = .highShelf
            case "HP", "HPQ": kind = .lowCut
            case "LP", "LPQ": kind = .highCut
            case "NO": kind = .notch
            case "BP": kind = .bandPass
            default: kind = nil
            }
            guard let kind, let fc = value(after: "Fc", in: tokens) else { continue }
            var band = EQBand(type: kind, frequency: fc, gain: value(after: "Gain", in: tokens) ?? 0)
            if let q = value(after: "Q", in: tokens) { band.q = q }
            else if let bw = value(after: "BW", in: tokens) { band.q = EQBand.q(fromOctaves: bw) }
            bands.append(band.clamped(gainLimit: 30))
        }
        guard !bands.isEmpty else { return nil }
        return EQProfile(id: id, name: name, bands: bands, preampGain: preamp)
    }

    /// One "Preamp:" line, then one "Filter N:" line per band, each ending in "\n".
    public static func export(_ data: EqualizerSettingsData) -> String {
        var lines = ["Preamp: " + TextTools.fixed(data.preampGain, 1) + " dB"]
        for (i, b) in data.bands.enumerated() {
            let code: String
            switch b.type {
            case .bell: code = "PK"
            case .lowShelf: code = "LSC"
            case .highShelf: code = "HSC"
            case .lowCut: code = "HP"
            case .highCut: code = "LP"
            case .notch: code = "NO"
            case .bandPass: code = "BP"
            }
            var line = "Filter \(i + 1): \(b.enabled ? "ON" : "OFF") \(code) Fc \(TextTools.fixed(b.frequency, 0)) Hz"
            if b.type.hasGain { line += " Gain " + TextTools.fixed(b.gain, 1) + " dB" }
            if b.type.hasQ || b.type.hasGain { line += " Q " + TextTools.fixed(b.q, 2) }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func value(after key: String, in tokens: [String]) -> Double? {
        let k = key.lowercased()
        guard let i = tokens.firstIndex(where: { $0.lowercased() == k }), i + 1 < tokens.count else { return nil }
        return Double(TextTools.replacing(tokens[i + 1], ",", with: "."))
    }

    private static func number(after prefix: String, in line: String) -> Double? {
        let rest = TextTools.trimming(String(line.dropFirst(prefix.count)), TextTools.isWhitespace)
        return Double(rest.split(separator: " ").first.map(String.init) ?? "")
    }
}

// MARK: - Math without Foundation

enum EQMath {
    static let ln2 = 0.6931471805599453
    static let ln10 = 2.302585092994046

    static func asinh(_ x: Double) -> Double {
        let a = abs(x)
        let r = Math.log(a + (a * a + 1).squareRoot())
        return x < 0 ? -r : r
    }

    static func sinh(_ x: Double) -> Double { (Math.exp(x) - Math.exp(-x)) / 2 }

    static func log10(_ x: Double) -> Double { Math.log(x) / ln10 }

    /// An array of numbers, or nil if anything else is in it.
    static func doubles(_ v: JSON) -> [Double]? {
        guard let items = v.array else { return nil }
        var out: [Double] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let d = item.double else { return nil }
            out.append(d)
        }
        return out
    }

    static func bools(_ v: JSON) -> [Bool]? {
        guard let items = v.array else { return nil }
        var out: [Bool] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let b = item.bool else { return nil }
            out.append(b)
        }
        return out
    }
}
