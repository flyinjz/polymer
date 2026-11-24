// Additional theme-driven controls: text field, segmented control, progress bar,
// badge, tabs, and floating popover built strictly on PolymerUI, PolymerApp, and PolymerDesign.
import PolymerApp
import PolymerBase
import PolymerText
import PolymerUI

// MARK: PolymerTextField

/// Theme-styled single-line text field wrapping `PolymerUI.TextField` with focus border,
/// themed surface fill, corner radii, spacing, and focus ring.
public struct PolymerTextField: View {
    private enum Source {
        case text(Binding<String>)
        case state(Binding<TextEditorState>)
    }

    public let placeholder: String
    private let source: Source
    public let onSubmit: (@MainActor () -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @FocusState private var isFocused: Bool

    public init(
        _ placeholder: String = "",
        text: Binding<String>,
        onSubmit: (@MainActor () -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self.source = .text(text)
        self.onSubmit = onSubmit
    }

    public init(
        _ placeholder: String = "",
        state: Binding<TextEditorState>,
        onSubmit: (@MainActor () -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self.source = .state(state)
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let radius = theme.radii.small
        let bw = theme.borders.borderWidth
        let hPad = theme.spacing.sm * customizeScale
        let vPad = theme.spacing.xs * customizeScale
        let bgColor = isEnabled ? theme.colors.surface : theme.colors.background
        let fgColor = isEnabled ? theme.colors.textPrimary : theme.colors.textDisabled
        let borderColor: Color = {
            if !isEnabled { return theme.colors.hairline }
            if isFocused { return theme.colors.accent }
            return theme.colors.border
        }()

        container(
            bgColor: bgColor,
            fgColor: fgColor,
            borderColor: borderColor,
            radius: radius,
            borderWidth: bw,
            horizontalPadding: hPad,
            verticalPadding: vPad
        )
        .focused($isFocused)
        .focusRing(isFocused: isFocused)
    }

    @ViewBuilder
    private func rawField(fgColor: Color) -> some View {
        switch source {
        case .text(let binding):
            TextField(placeholder, text: binding, onSubmit: onSubmit)
                .foregroundStyle(fgColor)
        case .state(let binding):
            TextField(placeholder, state: binding, onSubmit: onSubmit)
                .foregroundStyle(fgColor)
        }
    }

    @ViewBuilder
    private func container(
        bgColor: Color,
        fgColor: Color,
        borderColor: Color,
        radius: Double,
        borderWidth: Double,
        horizontalPadding: Double,
        verticalPadding: Double
    ) -> some View {
        if radius > 0 {
            rawField(fgColor: fgColor)
                .padding(horizontal: horizontalPadding, vertical: verticalPadding)
                .background(ThemedSurfaceFill(color: bgColor, cornerRadius: max(0, radius - borderWidth)))
                .padding(borderWidth)
                .background(ThemedSurfaceFill(color: borderColor, cornerRadius: radius))
        } else {
            rawField(fgColor: fgColor)
                .padding(horizontal: horizontalPadding, vertical: verticalPadding)
                .background(ThemedSurfaceFill(color: bgColor, cornerRadius: 0))
                .border(borderColor, width: borderWidth)
        }
    }
}

// MARK: PolymerSegmentedControl

/// Horizontal themed segmented selector supporting pointer click and Left/Right keyboard navigation.
public struct PolymerSegmentedControl<Option: Hashable & Sendable>: View {
    public let options: [(Option, String)]
    @Binding public var selection: Option

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @FocusState private var isFocused: Bool

    public init(options: [(Option, String)], selection: Binding<Option>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        let radius = theme.radii.small
        let bw = theme.borders.borderWidth
        let borderColor = isEnabled ? theme.colors.border : theme.colors.hairline
        let innerRadius = max(0, radius - bw)

        if options.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: bw) {
                ForEach(0..<options.count) { idx in
                    let option = options[idx].0
                    let title = options[idx].1
                    SegmentedOptionCell(
                        title: title,
                        isSelected: option == selection,
                        cornerRadius: innerRadius,
                        onSelect: {
                            guard isEnabled else { return }
                            selection = option
                        }
                    )
                    .layoutPriority(1)
                }
            }
            .padding(bw)
            .background(ThemedSurfaceFill(color: borderColor, cornerRadius: radius))
            .focusable()
            .focused($isFocused)
            .focusRing(isFocused: isFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in
                guard isEnabled, !options.isEmpty else { return .ignored }
                let current = options.firstIndex(where: { $0.0 == selection }) ?? 0
                switch press.key {
                case .leftArrow:
                    let next = max(0, current - 1)
                    selection = options[next].0
                    return .handled
                case .rightArrow:
                    let next = min(options.count - 1, current + 1)
                    selection = options[next].0
                    return .handled
                case .home:
                    selection = options[0].0
                    return .handled
                case .end:
                    selection = options[options.count - 1].0
                    return .handled
                default:
                    return .ignored
                }
            }
        }
    }
}

private struct SegmentedOptionCell: View {
    let title: String
    let isSelected: Bool
    let cornerRadius: Double
    let onSelect: @MainActor () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @State private var isHovered = false

    var body: some View {
        let bg: Color = {
            if !isEnabled {
                return isSelected ? theme.colors.surfaceElevated : theme.colors.background
            }
            if isSelected { return theme.colors.accent }
            if isHovered { return theme.colors.hover }
            return theme.colors.surface
        }()
        let fg: Color = {
            if !isEnabled { return theme.colors.textDisabled }
            if isSelected { return theme.colors.accentText }
            return theme.colors.textSecondary
        }()

        Text(title)
            .lineLimit(1)
            .foregroundStyle(fg)
            .padding(horizontal: theme.spacing.md * customizeScale, vertical: theme.spacing.xs * customizeScale)
            .background(ThemedSurfaceFill(color: bg, cornerRadius: cornerRadius))
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
    }
}

// MARK: PolymerProgressBar

/// Determinate themed progress bar (`0...1`) with optional label and percentage readout.
public struct PolymerProgressBar: View {
    public let value: Double
    public let label: String?
    public let showsPercentage: Bool
    public let trackWidth: Double
    public let trackHeight: Double

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale

    public init(
        value: Double,
        label: String? = nil,
        showsPercentage: Bool = false,
        width: Double = 180,
        height: Double = 6
    ) {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        self.value = clamped
        self.label = label
        self.showsPercentage = showsPercentage
        self.trackWidth = max(20, width)
        self.trackHeight = max(2, height)
    }

    public var body: some View {
        let w = trackWidth * customizeScale
        let h = trackHeight * customizeScale
        let fillW = w * value
        let radius = theme.radii.pill > 0 ? h / 2 : 0
        let fillColor = isEnabled ? theme.colors.accent : theme.colors.textDisabled
        let percentText = "\(Int((value * 100).rounded()))%"

        VStack(alignment: .leading, spacing: theme.spacing.xs * customizeScale) {
            if label != nil || showsPercentage {
                HStack(spacing: theme.spacing.sm * customizeScale) {
                    if let label, !label.isEmpty {
                        Text(label)
                            .foregroundStyle(isEnabled ? theme.colors.textPrimary : theme.colors.textDisabled)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: theme.spacing.xs)
                    if showsPercentage {
                        Text(percentText)
                            .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textDisabled)
                            .layoutPriority(1)
                    }
                }
                .frame(width: w)
            }

            ZStack(alignment: .leading) {
                ThemedSurfaceFill(color: theme.colors.surfaceElevated, cornerRadius: radius)
                    .frame(width: w, height: h)
                if fillW > 0 {
                    ThemedSurfaceFill(color: fillColor, cornerRadius: radius)
                        .frame(width: fillW, height: h)
                }
            }
            .frame(width: w, height: h, alignment: .leading)
        }
    }
}

// MARK: PolymerBadge

/// Compact themed status pill/tag supporting neutral, accent, success, warning, and danger tones.
public struct PolymerBadge: View {
    public enum Tone: String, CaseIterable, Equatable, Hashable, Sendable {
        case neutral
        case accent
        case success
        case warning
        case danger
    }

    public let text: String
    public let tone: Tone

    @Environment(\.theme) private var theme
    @Environment(\.customizeScale) private var customizeScale

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        let palette = resolvedPalette
        let radius = theme.radii.small
        let bw = theme.borders.borderWidth
        let hPad = theme.spacing.sm * customizeScale
        let vPad = theme.spacing.xxs * customizeScale

        if radius > 0 {
            Text(text)
                .foregroundStyle(palette.foreground)
                .padding(horizontal: hPad, vertical: vPad)
                .background(ThemedSurfaceFill(color: palette.background, cornerRadius: max(0, radius - bw)))
                .padding(bw)
                .background(ThemedSurfaceFill(color: palette.border, cornerRadius: radius))
        } else {
            Text(text)
                .foregroundStyle(palette.foreground)
                .padding(horizontal: hPad, vertical: vPad)
                .background(ThemedSurfaceFill(color: palette.background, cornerRadius: 0))
                .border(palette.border, width: bw)
        }
    }

    private var resolvedPalette: (background: Color, foreground: Color, border: Color) {
        let c = theme.colors
        switch tone {
        case .neutral:
            return (c.surfaceElevated, c.textSecondary, c.border)
        case .accent:
            return (c.accent, c.accentText, c.accent)
        case .success:
            return (c.success, c.accentText, c.success)
        case .warning:
            let ink = theme.isDark ? c.background : c.accentText
            return (c.warning, ink, c.warning)
        case .danger:
            return (c.danger, c.accentText, c.danger)
        }
    }
}

// MARK: PolymerTabs

/// Tab bar + active content container with bottom accent underline indicator and hairline divider.
public struct PolymerTabs<Tab: Hashable & Sendable, Content: View>: View {
    public let tabs: [(Tab, String)]
    @Binding public var selection: Tab
    private let content: (Tab) -> Content

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale

    public init(
        tabs: [(Tab, String)],
        selection: Binding<Tab>,
        @ViewBuilder content: @escaping (Tab) -> Content
    ) {
        self.tabs = tabs
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: theme.spacing.sm * customizeScale) {
                ForEach(0..<tabs.count) { idx in
                    let tab = tabs[idx].0
                    let title = tabs[idx].1
                    TabBarButton(
                        title: title,
                        isSelected: tab == selection,
                        onSelect: {
                            guard isEnabled else { return }
                            selection = tab
                        }
                    )
                }
            }
            HairlineDivider(axis: .horizontal)
            content(selection)
                .id(selection)
                .padding(EdgeInsets(top: theme.spacing.sm * customizeScale, leading: 0, bottom: 0, trailing: 0))
        }
    }
}

private struct TabBarButton: View {
    let title: String
    let isSelected: Bool
    let onSelect: @MainActor () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.customizeScale) private var customizeScale
    @State private var isHovered = false

    var body: some View {
        let indicatorH = max(2.0, theme.borders.borderWidth * 2) * customizeScale
        let fg: Color = {
            if !isEnabled { return theme.colors.textDisabled }
            if isSelected { return theme.colors.textPrimary }
            return isHovered ? theme.colors.textPrimary : theme.colors.textSecondary
        }()
        let bg: Color = (!isSelected && isEnabled && isHovered) ? theme.colors.hover : .clear
        let indicatorColor: Color = isSelected
            ? (isEnabled ? theme.colors.accent : theme.colors.textDisabled)
            : .clear

        Button(action: onSelect) {
            Text(title)
                .foregroundStyle(fg)
                .padding(EdgeInsets(
                    top: theme.spacing.xs * customizeScale,
                    leading: theme.spacing.sm * customizeScale,
                    bottom: (theme.spacing.xs * customizeScale) + indicatorH,
                    trailing: theme.spacing.sm * customizeScale
                ))
                .background(ThemedSurfaceFill(color: bg, cornerRadius: theme.radii.small))
                .overlay(
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ThemedSurfaceFill(color: indicatorColor, cornerRadius: 0)
                            .frame(height: indicatorH)
                    }
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: PolymerPopover

/// Elevated themed floating popover surface with border, Escape key handling, and optional dismiss button.
public struct PolymerPopover<Content: View>: View {
    public let minWidth: Double
    public let maxWidth: Double
    public let onDismiss: (@MainActor () -> Void)?
    private let content: Content

    @Environment(\.theme) private var theme
    @Environment(\.customizeScale) private var customizeScale

    public init(
        minWidth: Double = 180,
        maxWidth: Double = 260,
        onDismiss: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        let lo = max(80, minWidth)
        self.minWidth = lo
        self.maxWidth = max(lo, maxWidth)
        self.onDismiss = onDismiss
        self.content = content()
    }

    public var body: some View {
        let radius = theme.radii.medium
        let bw = theme.borders.borderWidth

        surface(radius: radius, borderWidth: bw)
            .onKeyPress(.escape) {
                guard let onDismiss else { return .ignored }
                onDismiss()
                return .handled
            }
    }

    private var innerBody: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs * customizeScale) {
            if let onDismiss {
                HStack(spacing: theme.spacing.sm) {
                    Spacer(minLength: 0)
                    Button("Close") { onDismiss() }
                        .buttonStyle(.polymerGhost)
                }
                HairlineDivider(axis: .horizontal)
            }
            content
        }
        .padding(theme.spacing.sm * customizeScale)
        .frame(minWidth: minWidth * customizeScale, maxWidth: maxWidth * customizeScale, alignment: .leading)
    }

    @ViewBuilder
    private func surface(radius: Double, borderWidth: Double) -> some View {
        if radius > 0 {
            innerBody
                .background(ThemedSurfaceFill(color: theme.colors.surfaceElevated, cornerRadius: max(0, radius - borderWidth)))
                .padding(borderWidth)
                .background(ThemedSurfaceFill(color: theme.colors.border, cornerRadius: radius))
        } else {
            innerBody
                .background(ThemedSurfaceFill(color: theme.colors.surfaceElevated, cornerRadius: 0))
                .border(theme.colors.border, width: borderWidth)
        }
    }
}

private struct PolymerPopoverModifier<Anchor: View, PopoverContent: View>: View {
    @Binding var isPresented: Bool
    let minWidth: Double
    let maxWidth: Double
    let alignment: Alignment
    let anchor: Anchor
    let popoverContent: PopoverContent

    @Environment(\.theme) private var theme
    @FocusState private var popoverFocused: Bool

    var body: some View {
        anchor
            .overlay(popoverLayer)
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    popoverFocused = true
                }
            }
            .onKeyPress(.escape) {
                guard isPresented else { return .ignored }
                isPresented = false
                return .handled
            }
    }

    @ViewBuilder
    private var popoverLayer: some View {
        if isPresented {
            ZStack(alignment: alignment) {
                Color.clear
                PolymerPopover(minWidth: minWidth, maxWidth: maxWidth, onDismiss: { isPresented = false }) {
                    popoverContent
                }
                .focusable()
                .focused($popoverFocused)
                .padding(theme.spacing.sm)
            }
            .zIndex(100)
        }
    }
}

extension View {
    /// Presents a themed floating `PolymerPopover` overlay while `isPresented` is true.
    public func polymerPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        minWidth: Double = 180,
        maxWidth: Double = 260,
        alignment: Alignment = .center,
        @ViewBuilder content: () -> PopoverContent
    ) -> some View {
        PolymerPopoverModifier(
            isPresented: isPresented,
            minWidth: minWidth,
            maxWidth: maxWidth,
            alignment: alignment,
            anchor: self,
            popoverContent: content()
        )
    }
}
