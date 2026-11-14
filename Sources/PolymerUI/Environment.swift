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
