// JSON (RFC 8259): a value type, a strict parser with line and column in
// its errors, and deterministic output (keys sorted, shortest round-trip
// numbers), so the same value prints the same bytes on every OS.

public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Access

    @inlinable public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    @inlinable public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }
    @inlinable public var double: Double? { if case .number(let n) = self { return n }; return nil }
    @inlinable public var int: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 9_007_199_254_740_992 { return Int(n) }
        return nil
    }
    @inlinable public var string: String? { if case .string(let s) = self { return s }; return nil }
    @inlinable public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    @inlinable public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    @inlinable public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    @inlinable public var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Parse

    public struct ParseError: Error, Sendable, CustomStringConvertible {
        public let message: String
        public let line: Int
        public let column: Int
        public var description: String { "JSON error at line \(line), column \(column): \(message)" }
    }

    public static func parse(_ text: String) throws(ParseError) -> JSON {
        try parse(Array(text.utf8))
    }

    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> JSON {
        var p = JSONParser(bytes: bytes)
        // Skip a UTF-8 byte order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { p.i = 3 }
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        if p.i < bytes.count { throw p.error("unexpected text after the value; a file holds one JSON value") }
        return v
    }

    // MARK: Output

    /// Compact output, keys sorted.
    public var serialized: String {
        var out: [UInt8] = []
        write(to: &out, indent: nil, level: 0)
        return String(decoding: out, as: UTF8.self)
    }

    /// Indented with two spaces, keys sorted, trailing newline.
    public var pretty: String {
        var out: [UInt8] = []
        write(to: &out, indent: 2, level: 0)
        out.append(0x0A)
        return String(decoding: out, as: UTF8.self)
    }

    func write(to out: inout [UInt8], indent: Int?, level: Int) {
        func newline(_ l: Int) {
            guard let indent else { return }
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: indent * l))
        }
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .number(let n): out.append(contentsOf: JSON.format(n).utf8)
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let a):
            out.append(0x5B)
            for (k, v) in a.enumerated() {
                if k > 0 { out.append(0x2C) }
                newline(level + 1)
                v.write(to: &out, indent: indent, level: level + 1)
            }
            if !a.isEmpty { newline(level) }
            out.append(0x5D)
        case .object(let o):
            out.append(0x7B)
            for (k, key) in o.keys.sorted().enumerated() {
                if k > 0 { out.append(0x2C) }
                newline(level + 1)
                JSON.writeString(key, to: &out)
                out.append(0x3A)
                if indent != nil { out.append(0x20) }
                o[key]!.write(to: &out, indent: indent, level: level + 1)
            }
            if !o.isEmpty { newline(level) }
            out.append(0x7D)
        }
    }

    /// Integers without a fraction; others shortest round-trip. Non-finite numbers become null.
    static func format(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return n.description
    }

    static func writeString(_ s: String, to out: inout [UInt8]) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 15)]])
            default: out.append(b)
            }
        }
        out.append(0x22)
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(stringLiteral v: String) { self = .string(v) }
    public init(arrayLiteral v: JSON...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, x) in v { o[k] = x }
        self = .object(o)
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func error(_ message: String) -> JSON.ParseError {
        var line = 1, col = 1
        for k in 0..<min(i, bytes.count) {
            if bytes[k] == 0x0A { line += 1; col = 1 } else if bytes[k] & 0xC0 != 0x80 { col += 1 }
        }
        return JSON.ParseError(message: message, line: line, column: col)
    }

    mutating func skipSpace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    mutating func literal(_ word: String, _ v: JSON) throws(JSON.ParseError) -> JSON {
        for b in word.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw error("expected '\(word)'") }
            i += 1
        }
        return v
    }

    mutating func value(depth: Int) throws(JSON.ParseError) -> JSON {
        guard depth < 512 else { throw error("nesting deeper than 512 levels") }
        guard i < bytes.count else { throw error("expected a value but the text ended") }
        switch bytes[i] {
        case 0x7B: return try object(depth: depth)
        case 0x5B: return try array(depth: depth)
        case 0x22: return .string(try string())
        case 0x74: return try literal("true", .bool(true))
        case 0x66: return try literal("false", .bool(false))
        case 0x6E: return try literal("null", .null)
        case 0x2D, 0x30...0x39: return .number(try number())
        default: throw error("expected a value (object, array, string, number, true, false or null)")
        }
    }

    mutating func object(depth: Int) throws(JSON.ParseError) -> JSON {
        i += 1
        var o: [String: JSON] = [:]
        skipSpace()
        if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(o) }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x22 else { throw error("expected a quoted key") }
            let key = try string()
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x3A else { throw error("expected ':' after the key \"\(key)\"") }
            i += 1
            skipSpace()
            if o[key] != nil { throw error("duplicate key \"\(key)\"") }
            o[key] = try value(depth: depth + 1)
            skipSpace()
            guard i < bytes.count else { throw error("object not closed; add '}'") }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { i += 1; return .object(o) }
            throw error("expected ',' or '}' in object")
        }
    }

    mutating func array(depth: Int) throws(JSON.ParseError) -> JSON {
        i += 1
        var a: [JSON] = []
        skipSpace()
        if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(a) }
        while true {
            skipSpace()
            a.append(try value(depth: depth + 1))
            skipSpace()
            guard i < bytes.count else { throw error("array not closed; add ']'") }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x5D { i += 1; return .array(a) }
            throw error("expected ',' or ']' in array")
        }
    }

    mutating func hex4() throws(JSON.ParseError) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard i < bytes.count else { throw error("unfinished \\u escape") }
            let c = bytes[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw error("\\u needs four hex digits")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func string() throws(JSON.ParseError) -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("string not closed; add '\"'") }
            let c = bytes[i]
            if c == 0x22 { i += 1; break }
            if c < 0x20 { throw error("control character in string; escape it (\\n, \\t, \\u00XX)") }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw error("unfinished escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var u = try hex4()
                if u >= 0xD800, u < 0xDC00 {
                    guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else {
                        throw error("lone high surrogate; follow it with \\uDC00-\\uDFFF")
                    }
                    i += 2
                    let lo = try hex4()
                    guard lo >= 0xDC00, lo < 0xE000 else { throw error("invalid low surrogate") }
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                } else if u >= 0xDC00, u < 0xE000 {
                    throw error("lone low surrogate")
                }
                out.append(contentsOf: String(Character(Unicode.Scalar(u)!)).utf8)
            default: throw error("unknown escape '\\\(Character(Unicode.Scalar(e)))'")
            }
        }
        guard let s = String(validating: out, as: UTF8.self) else { throw error("string is not valid UTF-8") }
        return s
    }

    mutating func number() throws(JSON.ParseError) -> Double {
        let start = i
        if bytes[i] == 0x2D { i += 1 }
        func digits(_ i: inout Int) -> Int {
            let s = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i - s
        }
        guard i < bytes.count else { throw error("number has no digits") }
        if bytes[i] == 0x30 { i += 1 } else if digits(&i) == 0 { throw error("number has no digits") }
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            if digits(&i) == 0 { throw error("digits needed after '.'") }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            if digits(&i) == 0 { throw error("digits needed in exponent") }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        guard let v = Double(text) else { throw error("number out of range") }
        return v
    }
}
