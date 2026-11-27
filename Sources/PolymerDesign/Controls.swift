// Controls in the house look: a toggle, a slider, a progress bar, a
// segmented control and a picker. Square, 1-point lines, the accent for
// what is on or chosen. Each is a `Component`: a path, a right-click menu
// with Customize.
import PolymerBase
import PolymerUI

// MARK: Toggle

/// An on/off switch with its title: `PToggle("Shuffle", isOn: $shuffle)`.
/// Click it (anywhere on the row), or Tab to it and press Space.
public struct PToggle: View {
    let title: String
    let name: String?
    let isOn: Binding<Bool>
    let commands: [Command]
    @Environment(\.isEnabled) var isEnabled
    @FocusState var focused: Bool

    public init(_ title: String, isOn: Binding<Bool>, name: String? = nil, commands: [Command] = []) {
        self.title = title; self.isOn = isOn; self.name = name; self.commands = commands
    }

    public var body: some View {
        Component(name: name, role: "Toggle", title: title, commands: commands) { info in
            let t = info.theme
            let on = isOn.wrappedValue
            let binding = isOn
            Button(action: { binding.wrappedValue.toggle() }) {
                HStack(spacing: t.space.s) {
                    Text(title).textStyle(.body, t.gray.text, theme: t)
                    Spacer(minLength: t.space.s)
                    ToggleSwitch(isOn: on, theme: t).focusRing(focused, theme: t)
                }
                .frame(minHeight: t.size.control)
                .background(Rectangle().fill(Theme.hitFill))
            }
            .buttonStyle(PlainButtonStyle())
            .focused($focused)
            .opacity(isEnabled ? 1 : t.gray.disabledOpacity)
            .accessibilityLabel(title)
            .accessibilityValue(on ? "On" : "Off")
        }
    }
}

/// The switch itself: a track with a square knob, at the end it is on.
struct ToggleSwitch: View {
    let isOn: Bool
    let theme: Theme
    var body: some View {
        let t = theme
        let knob = t.size.toggleHeight - 4 * t.line
        ZStack(alignment: isOn ? .trailing : .leading) {
            Rectangle().fill(isOn ? t.accent : t.gray.raised)
            Color.clear.border(isOn ? t.accent : t.gray.strongLine, width: t.line)
            Rectangle().fill(isOn ? t.onAccent : t.gray.secondaryText)
                .frame(width: knob, height: knob)
                .padding(2 * t.line)
        }
        .frame(width: t.size.toggleWidth, height: t.size.toggleHeight)
    }
}

// MARK: Slider

/// A value in a range, set by dragging or by the arrow keys:
/// `PSlider("Volume", value: $volume, in: 0...1)`.
public struct PSlider: View {
    let title: String
    let name: String?
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let commands: [Command]
    @Environment(\.isEnabled) var isEnabled
    @FocusState var focused: Bool

    /// `step` rounds values to multiples of it; the arrow keys move by it (a
    /// twentieth of the range without one). Home and End go to the ends.
    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil,
                name: String? = nil, commands: [Command] = []) {
        self.title = title; self.value = value; self.range = range; self.step = step
        self.name = name; self.commands = commands
    }

    public var body: some View {
        Component(name: name, role: "Slider", title: title, commands: commands) { info in
            let t = info.theme
            let f = fraction(value.wrappedValue)
            let enabled = isEnabled
            GeometryReader { p in
                let thumb = t.size.thumb
                let travel = max(p.size.width - thumb, 0)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.hitFill)
                    Rectangle().fill(t.gray.strongLine).frame(height: 2 * t.line)
                    Rectangle().fill(t.accent).frame(width: travel * f + thumb / 2, height: 2 * t.line)
                    Rectangle().fill(t.gray.text)
                        .frame(width: thumb, height: thumb)
                        .border(focused ? t.accent : t.gray.background, width: t.line)
                        .offset(x: travel * f)
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    guard enabled else { return }
                    set(travel > 0 ? (v.location.x - thumb / 2) / travel : 0)
                })
            }
            .frame(minWidth: 4 * t.size.thumb, minHeight: t.size.control, maxHeight: t.size.control)
            .focusable(enabled)
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
                guard enabled else { return .ignored }
                let by = (step ?? (range.upperBound - range.lowerBound) / 20) / max(range.upperBound - range.lowerBound, .ulpOfOne)
                let now = fraction(value.wrappedValue)
                switch press.key {
                case .leftArrow, .downArrow: set(now - by)
                case .rightArrow, .upArrow: set(now + by)
                case .home: set(0)
                default: set(1)
                }
                return .handled
            }
            .opacity(enabled ? 1 : t.gray.disabledOpacity)
            .accessibilityLabel(title)
            .accessibilityValue(Self.format(value.wrappedValue))
        }
    }

    func fraction(_ v: Double) -> Double {
        let w = range.upperBound - range.lowerBound
        guard w > 0 else { return 0 }
        return min(max((v - range.lowerBound) / w, 0), 1)
    }

    /// Sets the value at `fraction` of the range, clamped and on the step.
    @MainActor func set(_ fraction: Double) {
        let f = min(max(fraction, 0), 1)
        var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
        if let step, step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        v = min(max(v, range.lowerBound), range.upperBound)
        if v != value.wrappedValue { value.wrappedValue = v }
    }

    /// "0.25", "3": up to two decimals, no trailing zeros.
    static func format(_ v: Double) -> String {
        let hundredths = Int((v * 100).rounded())
        let whole = hundredths / 100, rest = abs(hundredths % 100)
        let sign = hundredths < 0 && whole == 0 ? "-" : ""
        if rest == 0 { return "\(sign)\(whole)" }
        let digits = rest % 10 == 0 ? "\(rest / 10)" : (rest < 10 ? "0\(rest)" : "\(rest)")
        return "\(sign)\(whole).\(digits)"
    }
}

// MARK: Progress

/// How far something has got, from 0 to 1: `PProgressBar("Import", value: 0.4)`.
public struct PProgressBar: View {
    let title: String
    let name: String?
    let value: Double

    public init(_ title: String, value: Double, name: String? = nil) {
        self.title = title; self.value = value; self.name = name
    }

    public var body: some View {
        let f = min(max(value, 0), 1)
        Component(name: name, role: "ProgressBar", title: title) { info in
            let t = info.theme
            GeometryReader { p in
                ZStack(alignment: .leading) {
                    Rectangle().fill(t.gray.raised)
                    Rectangle().fill(t.accent).frame(width: p.size.width * f)
                }
            }
            .frame(minWidth: 4 * t.size.progress, minHeight: t.size.progress, maxHeight: t.size.progress)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((f * 100).rounded()))%")
        }
    }
}

// MARK: Choices

/// One choice in a segmented control or picker.
public struct PickerOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    /// Its part of the path ("view/albums"); the title's slug by default.
    public let name: String
    public var id: String { name }
    public init(_ title: String, value: Value, name: String? = nil) {
        self.title = title; self.value = value; self.name = name ?? ElementPath.slug(title)
    }
}

/// A row of joined buttons, one chosen:
/// `PSegmentedControl("View", selection: $view, options: [PickerOption("Albums", value: .albums), ...])`.
/// Each segment is a part named by its option ("view/albums").
public struct PSegmentedControl<Value: Hashable>: View {
    let title: String
    let name: String?
    let selection: Binding<Value>
    let options: [PickerOption<Value>]
    let commands: [Command]
    @Environment(\.isEnabled) var isEnabled

    public init(_ title: String, selection: Binding<Value>, options: [PickerOption<Value>], name: String? = nil,
                commands: [Command] = []) {
        self.title = title; self.selection = selection; self.options = options; self.name = name; self.commands = commands
    }

    public var body: some View {
        Component(name: name, role: "SegmentedControl", title: title, commands: commands) { info in
            let t = info.theme
            let chosen = selection.wrappedValue
            let binding = selection
            HStack(spacing: 0) {
                ForEach(options) { o in
                    let on = o.value == chosen
                    Part(name: o.name, role: "Segment", title: o.title) {
                        Button(action: { if binding.wrappedValue != o.value { binding.wrappedValue = o.value } }) {
                            Text(o.title)
                                .textStyle(.body, on ? t.onAccent : t.gray.text, theme: t)
                                .padding(horizontal: t.space.m, vertical: 0)
                                .frame(minWidth: t.size.control, minHeight: t.size.control)
                                .background(Rectangle().fill(on ? t.accent : t.gray.raised))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(o.title)
                        .accessibilityValue(on ? "Selected" : "")
                    }
                    if o.id != options.last?.id {
                        Rectangle().fill(t.gray.line).frame(width: t.line, height: t.size.control)
                    }
                }
            }
            // `.border`, not a stroked shape: a stroke takes clicks across its whole frame.
            .border(t.gray.line, width: t.line)
            .opacity(isEnabled ? 1 : t.gray.disabledOpacity)
            .accessibilityLabel(title)
        }
    }
}

/// A button showing the current choice that opens a menu of the others:
/// `PPicker("Sort by", selection: $sort, options: [...])`.
public struct PPicker<Value: Hashable>: View {
    let title: String
    let name: String?
    let selection: Binding<Value>
    let options: [PickerOption<Value>]
    let commands: [Command]
    @Environment(\.isEnabled) var isEnabled
    @FocusState var focused: Bool

    public init(_ title: String, selection: Binding<Value>, options: [PickerOption<Value>], name: String? = nil,
                commands: [Command] = []) {
        self.title = title; self.selection = selection; self.options = options; self.name = name; self.commands = commands
    }

    public var body: some View {
        Component(name: name, role: "Picker", title: title, commands: commands) { info in
            let t = info.theme
            let current = options.first { $0.value == selection.wrappedValue }?.title ?? ""
            let binding = selection
            let options = options
            Menu(content: {
                ForEach(options) { o in
                    Button(o.title) { binding.wrappedValue = o.value }
                }
            }, label: {
                HStack(spacing: t.space.s) {
                    Text(current).textStyle(.body, t.gray.text, theme: t)
                    Spacer(minLength: t.space.s)
                    DownMark(theme: t)
                }
                .padding(horizontal: t.space.s, vertical: 0)
                .frame(minWidth: 4 * t.size.control, minHeight: t.size.control)
                .background(Rectangle().fill(t.gray.surface))
                .border(t.gray.line, width: t.line)
                .focusRing(focused, theme: t)
            })
            .buttonStyle(PlainButtonStyle())
            .focused($focused)
            .opacity(isEnabled ? 1 : t.gray.disabledOpacity)
            .accessibilityLabel(title)
            .accessibilityValue(current)
        }
    }
}

/// A small downward triangle built from 1-point bars (no glyph needed).
struct DownMark: View {
    let theme: Theme
    var body: some View {
        let u = theme.line
        VStack(spacing: 0) {
            Rectangle().fill(theme.gray.secondaryText).frame(width: 7 * u, height: u)
            Rectangle().fill(theme.gray.secondaryText).frame(width: 5 * u, height: u)
            Rectangle().fill(theme.gray.secondaryText).frame(width: 3 * u, height: u)
            Rectangle().fill(theme.gray.secondaryText).frame(width: u, height: u)
        }
    }
}
