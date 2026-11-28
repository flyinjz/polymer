// Lenient settings decoding: ported from Meimei's Persistence. Only the pure
// part is here (bytes in, value out; value in, bytes out). Reading and
// writing files is the caller's: pass `Platform.files.read(path)` to
// `decodeLeniently(from:)` and `encoded` to `Platform.files.write(_:to:)`.
// Meimei's UserDefaults store and its background coalescing file writer are
// not ported (no UserDefaults, Dispatch or locks in shared code).
import PolymerBase

/// Settings-style payloads that decode leniently: any key missing from the
/// stored JSON (an older build) or holding a value this build can't read
/// (a removed enum case) falls back to the type's default, so a stale
/// preference can never wipe out the rest of the user's customization.
/// Each top-level key is all-or-nothing; unknown keys are dropped.
public protocol LenientDecodable: Sendable {
    /// The defaults.
    init()
    /// Every key of `fields` this type knows and can read; the rest default.
    init(lenient fields: LenientFields)
    /// The stored form (every key, Meimei's names).
    var json: JSON { get }
}

extension LenientDecodable {
    /// Unparseable bytes, or JSON that is not an object, give the defaults.
    public static func decodeLeniently(from bytes: [UInt8]) -> Self {
        guard let value = try? JSON.parse(bytes), let object = value.object else { return Self() }
        return Self(lenient: LenientFields(object))
    }

    public static func decodeLeniently(from text: String) -> Self {
        decodeLeniently(from: Array(text.utf8))
    }

    public static func decodeLeniently(json: JSON) -> Self {
        guard let object = json.object else { return Self() }
        return Self(lenient: LenientFields(object))
    }

    /// Compact UTF-8 JSON, keys sorted, ready for `FileSystem.write`.
    public var encoded: [UInt8] { Array(json.serialized.utf8) }
}

/// Strict per-key readers. A key that is missing, null, or of the wrong
/// type or range gives the default; nothing is coerced (no number-as-bool,
/// no string-as-number), matching Swift's JSONDecoder.
public struct LenientFields: Hashable, Sendable {
    public let object: [String: JSON]

    public init(_ object: [String: JSON]) { self.object = object }

    public subscript(key: String) -> JSON? { object[key] }

    public func bool(_ key: String, _ fallback: Bool) -> Bool { object[key]?.bool ?? fallback }

    public func double(_ key: String, _ fallback: Double) -> Double { object[key]?.double ?? fallback }

    /// Whole numbers only (24 or 24.0; not 24.5).
    public func int(_ key: String, _ fallback: Int) -> Int { object[key]?.int ?? fallback }

    public func string(_ key: String, _ fallback: String) -> String { object[key]?.string ?? fallback }

    /// An enum stored by its raw string.
    public func value<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
        object[key]?.string.flatMap(E.init(rawValue:)) ?? fallback
    }

    /// An array of enums. One unreadable element and the whole array is the default.
    public func values<E: RawRepresentable>(_ key: String, _ fallback: [E]) -> [E] where E.RawValue == String {
        guard let items = object[key]?.array else { return fallback }
        var out: [E] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let v = item.string.flatMap(E.init(rawValue:)) else { return fallback }
            out.append(v)
        }
        return out
    }

    /// A string-to-UInt32 map (icon codepoints, 0xRRGGBB colours). One
    /// value that is not a whole number in 0...UInt32.max and the whole map
    /// is the default.
    public func codes(_ key: String, _ fallback: [String: UInt32]) -> [String: UInt32] {
        guard let items = object[key]?.object else { return fallback }
        var out: [String: UInt32] = [:]
        out.reserveCapacity(items.count)
        for (k, item) in items {
            guard let n = item.int, n >= 0, n <= Int(UInt32.max) else { return fallback }
            out[k] = UInt32(n)
        }
        return out
    }

    /// A nested object; missing or not an object gives nil.
    public func fields(_ key: String) -> LenientFields? {
        object[key]?.object.map(LenientFields.init)
    }
}

extension JSON {
    /// An enum's raw string.
    public static func raw<E: RawRepresentable>(_ v: E) -> JSON where E.RawValue == String { .string(v.rawValue) }

    public static func raws<E: RawRepresentable>(_ v: [E]) -> JSON where E.RawValue == String {
        .array(v.map { .string($0.rawValue) })
    }

    public static func codes(_ v: [String: UInt32]) -> JSON {
        var o: [String: JSON] = [:]
        o.reserveCapacity(v.count)
        for (k, n) in v { o[k] = .number(Double(n)) }
        return .object(o)
    }
}
