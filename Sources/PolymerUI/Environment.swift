// Environment values handed down the view tree, and Font.
import PolymerBase
import PolymerText

/// A font: a face at a size in points (SwiftUI's `Font`, without system fonts yet).
public struct Font: Hashable, Sendable {
    public let face: FontFace
    public let size: Double
    public init(_ face: FontFace, size: Double) { self.face = face; self.size = size }

    public static func == (a: Font, b: Font) -> Bool { a.face === b.face && a.size == b.size }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(face)); h.combine(size) }

    var scale: Double { size / Double(face.unitsPerEm) }
    /// Line height in points (ascender - descender + line gap), as CoreText.
    var lineHeight: Double { Double(face.ascender - face.descender + face.lineGap) * scale }
    var ascent: Double { Double(face.ascender) * scale }
}

/// How the lines of a wrapped text line up.
public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }

/// A value apps add to the environment: `extension EnvironmentValues { var x: X { get { self[XKey.self] } set { self[XKey.self] = newValue } } }`.
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    public var font: Font?
    public var foregroundColor: Color = .white
    /// Colour of `Divider` lines.
    public var separatorColor: Color = Color(white: 1, opacity: 0.14)
    public var textRendering: TextRenderingOptions = .standard
    /// Pixels per point of the display the view is drawn for.
    public var displayScale: Double = 1
    /// Most lines a `Text` may take; nil for as many as it needs.
    public var lineLimit: Int?
    public var multilineTextAlignment: TextAlignment = .leading
    /// The look of buttons; set with `.buttonStyle(_:)`.
    public var buttonStyle: any ButtonStyle = PlainButtonStyle()
    /// False inside `.disabled(true)`: buttons, tap handlers and focusable views stop responding.
    public var isEnabled = true

    private var custom: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { (custom[ObjectIdentifier(key)] as? K.Value) ?? K.defaultValue }
        set { custom[ObjectIdentifier(key)] = newValue }
    }

    /// True when every value is known to be the same as in `other`, so a view
    /// below that did not change needs nothing done. Values that can't be
    /// compared (neither `Equatable` nor a class instance) count as changed.
    func isSame(as other: EnvironmentValues) -> Bool {
        guard font == other.font, foregroundColor == other.foregroundColor, separatorColor == other.separatorColor,
              textRendering == other.textRendering, displayScale == other.displayScale, lineLimit == other.lineLimit,
              multilineTextAlignment == other.multilineTextAlignment, isEnabled == other.isEnabled,
              sameStyle(buttonStyle, other.buttonStyle), custom.count == other.custom.count else { return false }
        for (k, v) in custom {
            guard let o = other.custom[k], sameValue(v, o) else { return false }
        }
        return true
    }
}

/// Equal by `==`, or the same class instance.
private func sameValue(_ a: Any, _ b: Any) -> Bool {
    guard ObjectIdentifier(type(of: a)) == ObjectIdentifier(type(of: b)) else { return false }
    if let e = a as? any Equatable { return e.isEqual(to: b) }
    if type(of: a) is AnyObject.Type { return (a as AnyObject) === (b as AnyObject) }
    return false
}

/// Button styles: also the same when of one type with no stored properties.
private func sameStyle<S: ButtonStyle>(_ a: S, _ b: any ButtonStyle) -> Bool {
    guard let b = b as? S else { return false }
    return MemoryLayout<S>.size == 0 || sameValue(a, b)
}

extension Equatable {
    /// `==` against a value of unknown type; false when the types differ.
    func isEqual(to other: Any) -> Bool {
        guard let o = other as? Self else { return false }
        return self == o
    }
}

struct EnvironmentModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let change: (inout EnvironmentValues) -> Void
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        var c = c
        change(&c.environment)
        return reconcile(content, existing, c)
    }
}

extension View {
    public func font(_ font: Font) -> some View {
        EnvironmentModifier(content: self) { $0.font = font }
    }
    public func foregroundStyle(_ color: Color) -> some View {
        EnvironmentModifier(content: self) { $0.foregroundColor = color }
    }
    /// Most lines a text may take; longer text ends in an ellipsis. nil removes the limit.
    public func lineLimit(_ limit: Int?) -> some View {
        EnvironmentModifier(content: self) { $0.lineLimit = limit }
    }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        EnvironmentModifier(content: self) { $0.multilineTextAlignment = alignment }
    }
    /// Turns off buttons, tap handlers and focus in this view and everything inside it.
    /// `.disabled(false)` does not turn back on what an outer `.disabled(true)` turned off.
    public func disabled(_ disabled: Bool) -> some View {
        EnvironmentModifier(content: self) { if disabled { $0.isEnabled = false } }
    }
    /// Sets one environment value for this view and everything inside it.
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        EnvironmentModifier(content: self) { $0[keyPath: keyPath] = value }
    }
}
