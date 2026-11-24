// Theme-driven UI controls composed on PolymerUI and PolymerApp.
import PolymerApp
import PolymerBase
import PolymerUI

/// Internal fill helper that uses `Rectangle` when `cornerRadius <= 0` so sharp
/// presets such as `Theme.pgr` emit no `RoundedRectangle` nodes.
struct ThemedSurfaceFill: View {
    let color: Color
    let cornerRadius: Double

    var body: some View {
        if color.opacity <= 0 {
            EmptyView()
        } else if cornerRadius <= 0 {
            Rectangle().foregroundStyle(color)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius).foregroundStyle(color)
        }
    }
}

// MARK: HairlineDivider

/// A crisp 1-physical-pixel (or explicit theme-border) divider using `Theme.colors.hairline`.
public struct HairlineDivider: View {
    public let axis: Axis
    public let color: Color?

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    public init(axis: Axis = .horizontal, color: Color? = nil) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        let thickness = theme.borders.resolvedHairlineWidth(scale: displayScale)
        let lineColor = color ?? theme.colors.hairline
        if axis == .horizontal {
            Rectangle()
                .foregroundStyle(lineColor)
                .frame(maxWidth: .infinity)
                .frame(height: thickness)
        } else {
            Rectangle()
                .foregroundStyle(lineColor)
                .frame(maxHeight: .infinity)
                .frame(width: thickness)
        }
    }
}

// MARK: FocusRingModifier

/// Draws a themed keyboard/programmatic focus ring around a view without shifting its layout frame.
public struct FocusRingModifier<Content: View>: View {
    let content: Content
    let isFocused: Bool

    @Environment(\.theme) private var theme

    public init(isFocused: Bool, @ViewBuilder content: () -> Content) {
        self.isFocused = isFocused
        self.content = content()
    }

    public var body: some View {
        content.overlay(ringOverlay)
    }

    @ViewBuilder
    private var ringOverlay: some View {
        if isFocused {
            Color.clear.border(theme.focusRing.color, width: theme.focusRing.lineWidth)
        }
    }
}

extension View {
    /// Overlays the active theme's focus ring when `isFocused` is true.
    public func focusRing(isFocused: Bool) -> some View {
        FocusRingModifier(isFocused: isFocused) { self }
    }
}

// MARK: PolymerButtonStyle

/// Theme-aware button style with `.primary`, `.secondary`, `.ghost`, and `.destructive` variants.
public struct PolymerButtonStyle: ButtonStyle, Equatable, Hashable, Sendable {
    public enum Variant: String, CaseIterable, Equatable, Hashable, Sendable {
        case primary
        case secondary
        case ghost
        case destructive
    }

    public var variant: Variant

    public init(_ variant: Variant = .secondary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        PolymerButtonBody(variant: variant, configuration: configuration)
    }
}

extension ButtonStyle where Self == PolymerButtonStyle {
    public static var polymer: PolymerButtonStyle { PolymerButtonStyle(.secondary) }
    public static func polymer(_ variant: PolymerButtonStyle.Variant) -> PolymerButtonStyle {
        PolymerButtonStyle(variant)
    }
    public static var polymerPrimary: PolymerButtonStyle { PolymerButtonStyle(.primary) }
    public static var polymerSecondary: PolymerButtonStyle { PolymerButtonStyle(.secondary) }
    public static var polymerGhost: PolymerButtonStyle { PolymerButtonStyle(.ghost) }
    public static var polymerDestructive: PolymerButtonStyle { PolymerButtonStyle(.destructive) }
}

private struct PolymerButtonBody: View {
    let variant: PolymerButtonStyle.Variant
    let configuration: ButtonStyleConfiguration

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @State private var isHovered = false

    var body: some View {
        let palette = resolvedPalette
        let radius = theme.radii.small
        let bw = palette.border.opacity > 0 ? theme.borders.borderWidth : 0
        let hPad = theme.spacing.md * customizeScale
        let vPad = theme.spacing.xs * customizeScale

        configuration.label
            .foregroundStyle(palette.foreground)
            .padding(horizontal: hPad, vertical: vPad)
            .background(ThemedSurfaceFill(color: palette.background, cornerRadius: max(0, radius - bw)))
            .padding(bw)
            .background(ThemedSurfaceFill(color: palette.border, cornerRadius: radius))
            .onHover { isHovered = $0 }
    }

    private var resolvedPalette: (background: Color, foreground: Color, border: Color) {
        let c = theme.colors
        switch variant {
        case .primary:
            if !isEnabled { return (c.surface, c.textDisabled, c.hairline) }
            if configuration.isPressed { return (c.pressed, c.accentText, c.accent) }
            if isHovered { return (c.selection, c.accentText, c.selection) }
            return (c.accent, c.accentText, c.accent)
        case .secondary:
            if !isEnabled { return (c.background, c.textDisabled, c.hairline) }
            if configuration.isPressed { return (c.pressed, c.textPrimary, c.border) }
            if isHovered { return (c.hover, c.textPrimary, c.border) }
            return (c.surfaceElevated, c.textPrimary, c.border)
        case .ghost:
            if !isEnabled { return (.clear, c.textDisabled, .clear) }
            if configuration.isPressed { return (c.pressed, c.textPrimary, .clear) }
            if isHovered { return (c.hover, c.textPrimary, .clear) }
            return (.clear, c.textPrimary, .clear)
        case .destructive:
            if !isEnabled { return (c.surface, c.textDisabled, c.hairline) }
            if configuration.isPressed { return (c.pressed, c.accentText, c.danger) }
            return (c.danger, c.accentText, c.danger)
        }
    }
}

// MARK: PolymerToggle

/// Theme-aware boolean toggle switch with pointer click and Space/Return keyboard activation.
public struct PolymerToggle: View {
    public let label: String
    @Binding public var isOn: Bool

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    public var body: some View {
        let trackW = 36.0 * customizeScale
        let trackH = 20.0 * customizeScale
        let thumbSize = 14.0 * customizeScale
        let inset = (trackH - thumbSize) / 2
        let bw = theme.borders.borderWidth

        let trackFill: Color = {
            if !isEnabled { return theme.colors.surface }
            if isOn { return theme.colors.accent }
            return isHovered ? theme.colors.hover : theme.colors.surfaceElevated
        }()
        let trackBorder: Color = {
            if !isEnabled { return theme.colors.hairline }
            return isOn ? theme.colors.accent : theme.colors.border
        }()
        let thumbFill: Color = {
            if !isEnabled { return theme.colors.textDisabled }
            return isOn ? theme.colors.accentText : theme.colors.textPrimary
        }()

        Button(action: { isOn.toggle() }) {
            HStack(spacing: theme.spacing.sm * customizeScale) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .foregroundStyle(trackBorder)
                        .frame(width: trackW, height: trackH)
                    Capsule()
                        .foregroundStyle(trackFill)
                        .frame(width: max(0, trackW - 2 * bw), height: max(0, trackH - 2 * bw))
                        .padding(bw)
                    Circle()
                        .foregroundStyle(thumbFill)
                        .frame(width: thumbSize, height: thumbSize)
                        .padding(horizontal: inset)
                }
                .frame(width: trackW, height: trackH)

                if !label.isEmpty {
                    Text(label)
                        .foregroundStyle(isEnabled ? theme.colors.textPrimary : theme.colors.textDisabled)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusRing(isFocused: isFocused)
        .onHover { isHovered = $0 }
    }
}

// MARK: PolymerSlider

/// Theme-aware continuous or stepped slider supporting keyboard arrows and pointer track clicks.
public struct PolymerSlider: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let trackWidth: Double

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var dragStartValue: Double? = nil

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        width: Double = 180
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.trackWidth = max(40, width)
    }

    private var span: Double { max(1e-9, range.upperBound - range.lowerBound) }

    private var normalized: Double {
        min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var keyboardDelta: Double {
        if let step, step > 0 { return step }
        return span / 20.0
    }

    private var segmentCount: Int {
        if let step, step > 0 {
            let steps = Int((span / step).rounded())
            if steps >= 1 && steps <= 40 { return steps + 1 }
        }
        return 21
    }

    private func setClamped(_ raw: Double) {
        var next = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            let k = ((next - range.lowerBound) / step).rounded()
            next = min(max(range.lowerBound + k * step, range.lowerBound), range.upperBound)
        }
        value = next
    }

    public var body: some View {
        let width = trackWidth * customizeScale
        let trackH = 4.0 * customizeScale
        let thumbSize = 12.0 * customizeScale
        let controlH = max(18.0 * customizeScale, thumbSize + 4)
        let trackRadius = theme.radii.pill > 0 ? trackH / 2 : 0
        let thumbRadius = theme.radii.pill > 0 ? thumbSize / 2 : 0
        let fillW = width * normalized
        let thumbX = normalized * max(0, width - thumbSize)
        let segments = segmentCount
        let segW = width / Double(segments)

        let activeFill = isEnabled ? theme.colors.accent : theme.colors.textDisabled
        let thumbColor = isEnabled
            ? (isHovered ? theme.colors.accent : theme.colors.textPrimary)
            : theme.colors.textDisabled

        ZStack(alignment: .leading) {
            ThemedSurfaceFill(color: theme.colors.surfaceElevated, cornerRadius: trackRadius)
                .frame(width: width, height: trackH)
            if fillW > 0 {
                ThemedSurfaceFill(color: activeFill, cornerRadius: trackRadius)
                    .frame(width: fillW, height: trackH)
            }
            let bw = theme.borders.borderWidth
            if thumbRadius > 0 {
                ZStack {
                    ThemedSurfaceFill(color: theme.colors.border, cornerRadius: thumbRadius)
                        .frame(width: thumbSize, height: thumbSize)
                    ThemedSurfaceFill(color: thumbColor, cornerRadius: max(0, thumbRadius - bw))
                        .frame(width: max(0, thumbSize - 2 * bw), height: max(0, thumbSize - 2 * bw))
                }
                .offset(x: thumbX, y: 0)
            } else {
                ThemedSurfaceFill(color: thumbColor, cornerRadius: 0)
                    .frame(width: thumbSize, height: thumbSize)
                    .border(theme.colors.border, width: bw)
                    .offset(x: thumbX, y: 0)
            }

            if isEnabled {
                HStack(spacing: 0) {
                    ForEach(0..<segments) { idx in
                        Color(white: 0, opacity: 0.0001)
                            .frame(width: segW, height: controlH)
                            .onTapGesture {
                                let frac = segments > 1 ? Double(idx) / Double(segments - 1) : 0
                                setClamped(range.lowerBound + frac * span)
                            }
                    }
                }
                .frame(width: width, height: controlH)
            }
        }
        .frame(width: width, height: controlH, alignment: .leading)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    guard isEnabled else { return }
                    let base = dragStartValue ?? value
                    if dragStartValue == nil { dragStartValue = base }
                    let delta = (drag.translation.width / max(1, width)) * span
                    setClamped(base + delta)
                }
                .onEnded { _ in
                    dragStartValue = nil
                }
        )
        .focusable()
        .focused($isFocused)
        .focusRing(isFocused: isFocused)
        .onHover { isHovered = $0 }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow, .home, .end]) { press in
            guard isEnabled else { return .ignored }
            switch press.key {
            case .rightArrow, .upArrow:
                setClamped(value + keyboardDelta)
                return .handled
            case .leftArrow, .downArrow:
                setClamped(value - keyboardDelta)
                return .handled
            case .home:
                setClamped(range.lowerBound)
                return .handled
            case .end:
                setClamped(range.upperBound)
                return .handled
            default:
                return .ignored
            }
        }
    }
}

// MARK: PolymerScrollBar

/// Theme-styled overlay scroll indicator bar respecting `Theme.scrollIndicators` and `.scrollIndicators(_:)`.
public struct PolymerScrollBar: View {
    public let axis: Axis
    public let contentLength: Double
    public let viewportLength: Double
    public let offset: Double

    @Environment(\.theme) private var theme
    @Environment(\.scrollIndicatorVisibility) private var visibilityOverride
    @State private var isHovered = false

    public init(
        axis: Axis = .vertical,
        contentLength: Double,
        viewportLength: Double,
        offset: Double = 0
    ) {
        self.axis = axis
        self.contentLength = max(0, contentLength)
        self.viewportLength = max(0, viewportLength)
        self.offset = max(0, offset)
    }

    public var body: some View {
        let spec = theme.scrollIndicators
        let effectiveVisibility = visibilityOverride == .automatic ? spec.visibility : visibilityOverride
        let overflows = contentLength > viewportLength + 0.5
        let shouldShow: Bool = switch effectiveVisibility {
        case .hidden: false
        case .visible: viewportLength > 0
        case .automatic: overflows
        }

        if !shouldShow {
            EmptyView()
        } else {
            let trackLen = max(0, viewportLength - 2 * spec.inset)
            let ratio = contentLength > 0 ? min(1, viewportLength / contentLength) : 1
            let thumbLen = min(trackLen, max(spec.minLength, trackLen * ratio))
            let maxOff = max(0, contentLength - viewportLength)
            let progress = maxOff > 0 ? min(max(offset / maxOff, 0), 1) : 0
            let thumbPos = spec.inset + progress * max(0, trackLen - thumbLen)
            let fillColor = isHovered ? spec.hoverColor : spec.color

            if axis == .vertical {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: spec.thickness + 2 * spec.inset, height: viewportLength)
                    ThemedSurfaceFill(color: fillColor, cornerRadius: spec.cornerRadius)
                        .frame(width: spec.thickness, height: thumbLen)
                        .offset(x: spec.inset, y: thumbPos)
                }
                .frame(width: spec.thickness + 2 * spec.inset, height: viewportLength, alignment: .topLeading)
                .onHover { isHovered = $0 }
            } else {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: viewportLength, height: spec.thickness + 2 * spec.inset)
                    ThemedSurfaceFill(color: fillColor, cornerRadius: spec.cornerRadius)
                        .frame(width: thumbLen, height: spec.thickness)
                        .offset(x: thumbPos, y: spec.inset)
                }
                .frame(width: viewportLength, height: spec.thickness + 2 * spec.inset, alignment: .topLeading)
                .onHover { isHovered = $0 }
            }
        }
    }
}

// MARK: PolymerPanel

/// Themed container surface with optional backdrop glass, crisp border, padding, and corner radius.
public struct PolymerPanel<Content: View>: View {
    public let useGlass: Bool?
    public let padding: EdgeInsets?
    public let content: Content

    @Environment(\.theme) private var theme

    public init(
        useGlass: Bool? = nil,
        padding: EdgeInsets? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.useGlass = useGlass
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let glassOn = useGlass ?? theme.glass.enabled
        let insets = padding ?? EdgeInsets(all: theme.spacing.md)
        let radius = theme.radii.medium
        let bw = theme.borders.borderWidth

        content
            .padding(insets)
            .background(panelSurface(glassOn: glassOn, radius: max(0, radius - bw)))
            .border(theme.colors.border, width: bw)
    }

    @ViewBuilder
    private func panelSurface(glassOn: Bool, radius: Double) -> some View {
        if glassOn && theme.glass.blurRadius > 0 {
            ZStack {
                BackdropBlur(radius: theme.glass.blurRadius)
                ThemedSurfaceFill(color: theme.glass.tint, cornerRadius: radius)
            }
        } else {
            ThemedSurfaceFill(color: theme.colors.surface, cornerRadius: radius)
        }
    }
}

// MARK: PolymerContextMenu

/// Themed command menu / context-menu panel wired directly to `Command`s or a `CommandGroup`.
public struct PolymerContextMenu: View {
    public enum Entry: Sendable {
        case command(Command)
        case separator
    }

    public let entries: [Entry]
    public let minWidth: Double
    public let onDismiss: (@MainActor () -> Void)?

    @Environment(\.theme) private var theme

    public init(
        entries: [Entry],
        minWidth: Double = 180,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.entries = entries
        self.minWidth = minWidth
        self.onDismiss = onDismiss
    }

    public init(
        commands: [Command],
        minWidth: Double = 180,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.init(entries: commands.map { .command($0) }, minWidth: minWidth, onDismiss: onDismiss)
    }

    public init(
        group: CommandGroup,
        registry: CommandRegistry,
        minWidth: Double = 180,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        var resolved: [Entry] = []
        for item in group.items {
            switch item {
            case .separator:
                resolved.append(.separator)
            case .command(let id):
                if let cmd = registry.command(for: id) {
                    resolved.append(.command(cmd))
                }
            }
        }
        self.init(entries: resolved, minWidth: minWidth, onDismiss: onDismiss)
    }

    public var body: some View {
        let radius = theme.radii.small
        let bw = theme.borders.borderWidth

        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
            ForEach(0..<entries.count) { idx in
                switch entries[idx] {
                case .separator:
                    HairlineDivider()
                        .padding(vertical: theme.spacing.xs)
                case .command(let cmd):
                    ContextMenuRow(command: cmd, onDismiss: onDismiss)
                }
            }
        }
        .padding(vertical: theme.spacing.xs)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(ThemedSurfaceFill(color: theme.colors.surfaceElevated, cornerRadius: max(0, radius - bw)))
        .border(theme.colors.border, width: bw)
    }
}

private struct ContextMenuRow: View {
    let command: Command
    let onDismiss: (@MainActor () -> Void)?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let enabled = command.isEnabled()
        let checked = command.isChecked?() ?? false
        let bg: Color = (enabled && isHovered) ? theme.colors.hover : .clear
        let fg = enabled ? theme.colors.textPrimary : theme.colors.textDisabled

        Button(action: {
            guard command.isEnabled() else { return }
            command.perform()
            onDismiss?()
        }) {
            HStack(spacing: theme.spacing.sm) {
                Text(checked ? "*" : " ")
                    .foregroundStyle(enabled ? theme.colors.accent : theme.colors.textDisabled)
                    .layoutPriority(1)
                Text(command.title)
                    .foregroundStyle(fg)
                    .layoutPriority(1)
                Spacer(minLength: theme.spacing.md)
                if let shortcut = command.shortcut {
                    Text(shortcut.displayString)
                        .foregroundStyle(enabled ? theme.colors.textMuted : theme.colors.textDisabled)
                        .layoutPriority(1)
                }
            }
            .padding(horizontal: theme.spacing.md, vertical: theme.spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemedSurfaceFill(color: bg, cornerRadius: theme.radii.none))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
    }
}
