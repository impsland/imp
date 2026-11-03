import SwiftUI

// Steppers, small segmented choices, toggle buttons and a time field in the app's look. Each keeps
// the real control's behavior: VoiceOver gets a real `Stepper`, `Toggle` or buttons with the
// selected trait, and the keyboard, hover and disabled states work as everywhere else.

// MARK: - Stepper

/// A stepper in the app's look: your label, then a minus and a plus pill. VoiceOver and the
/// keyboard see a real `Stepper` (increment and decrement actions).
public struct ImpStepper<Value: Strideable, Label: View>: View {
    @Binding var value: Value
    let bounds: ClosedRange<Value>
    let step: Value.Stride
    let label: Label
    @Environment(\.isEnabled) private var enabled

    public init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1,
                @ViewBuilder label: () -> Label) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.label = label()
    }

    #if os(iOS)
    /// A full finger-sized target for each button on the iPhone.
    private static var nudgeSize: CGSize { CGSize(width: Sizing.hit, height: Sizing.hit) }
    #else
    private static var nudgeSize: CGSize { CGSize(width: 26, height: max(Sizing.hit - 8, 22)) }
    #endif

    private var lower: Value { max(bounds.lowerBound, value.advanced(by: -step)) }
    private var upper: Value { min(bounds.upperBound, value.advanced(by: step)) }

    public var body: some View {
        HStack(spacing: 8) {
            label
                .font(Typeface.body.monospacedDigit())
                .foregroundStyle(Dungeon.cream)
                .lineLimit(1)
            HStack(spacing: 2) {
                nudge("minus", "Less", to: lower, disabled: value <= bounds.lowerBound)
                nudge("plus", "More", to: upper, disabled: value >= bounds.upperBound)
            }
            .padding(2)
            .background(Capsule().fill(Dungeon.card))
            .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
            .opacity(enabled ? 1 : 0.45)
        }
        .accessibilityRepresentation {
            Stepper(value: $value, in: bounds, step: step) { label }
        }
    }

    private func nudge(_ symbol: String, _ help: LocalizedStringKey, to target: Value, disabled: Bool) -> some View {
        Button { value = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: Self.nudgeSize.width, height: Self.nudgeSize.height)
        }
        .buttonStyle(NudgeStyle())
        .disabled(disabled)
        .help(help)
    }

    private struct NudgeStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Nudge(configuration: configuration)
        }

        private struct Nudge: View {
            let configuration: Configuration
            @Environment(\.isEnabled) private var enabled
            @Environment(\.isFocused) private var focused
            @Environment(\.impTint) private var tint
            @State private var hover = false

            var body: some View {
                configuration.label
                    .foregroundStyle(Dungeon.cream)
                    .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : (hover ? 0.12 : 0.0))))
                    .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
                    .contentShape(Capsule())
                    .opacity(enabled ? 1 : 0.35)
                    .onHover { hover = $0 && enabled }
            }
        }
    }
}

// MARK: - Segmented choice

/// A short row of text choices in one pill, the chosen one lit in the Imp's colour. For a
/// handful of options on one line (`SegmentedTabs` is the page-wide one with icons).
public struct ImpSegmented<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Environment(\.impTint) private var tint
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    /// `label` names the whole control for VoiceOver. `title` names an option and is shown as is,
    /// so localize it first.
    #if os(iOS)
    /// On the iPhone the bar fills its row, so each choice is an easy target for a finger.
    private static var segmentWidth: CGFloat? { .infinity }
    private static var segmentPadding: CGFloat { 4 }
    #else
    /// On the Mac the bar is only as wide as its words.
    private static var segmentWidth: CGFloat? { nil }
    private static var segmentPadding: CGFloat { 12 }
    #endif

    public init(_ label: LocalizedStringKey, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    withImpAnimation(.snappy(duration: Timing.medium), reduceMotion: reduceMotion) { selection = option }
                } label: {
                    Text(verbatim: title(option))
                        .font(Typeface.label).lineLimit(1)
                        .foregroundStyle(on ? Color.white : Dungeon.muted)
                        .padding(.horizontal, Self.segmentPadding)
                        .frame(maxWidth: Self.segmentWidth, minHeight: max(Sizing.hit - 6, 22))
                        .background {
                            if on {
                                Capsule().fill(tint.gradient).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Dungeon.card))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
        .opacity(enabled ? 1 : 0.45)
        .fixedSize(horizontal: Self.segmentWidth == nil, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Toggle button

/// A toggle shown as a small pill button that lights up in the Imp's colour while it is on.
/// Still a `Toggle` for VoiceOver.
public struct ImpToggleButtonStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.impTint) private var tint
        @State private var hover = false

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Dungeon.cream)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(minHeight: 26)
                    .background(Capsule().fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.14 : 0.08))))
                    .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
                    .contentShape(Capsule())
                    .opacity(enabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 && enabled }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

extension ToggleStyle where Self == ImpToggleButtonStyle {
    /// A toggle that looks like a small pill button.
    public static var impButton: ImpToggleButtonStyle { ImpToggleButtonStyle() }
}

// MARK: - Time

/// A time of day in the app's look: an hour menu and a minute menu. It changes only the time of
/// day and leaves the date part of the binding as it was.
public struct ImpTimeField: View {
    @Binding var time: Date
    var calendar: Calendar

    public init(time: Binding<Date>, calendar: Calendar = .current) {
        _time = time
        self.calendar = calendar
    }

    private var hour: Int { calendar.component(.hour, from: time) }
    private var minute: Int { calendar.component(.minute, from: time) }

    private var minutes: [Int] {
        var all = Set(stride(from: 0, to: 60, by: 5))
        all.insert(minute)
        return all.sorted()
    }

    private func set(hour: Int? = nil, minute: Int? = nil) {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
        if let hour { parts.hour = hour }
        if let minute { parts.minute = minute }
        if let date = calendar.date(from: parts) { time = date }
    }

    private func hourName(_ h: Int) -> String {
        let date = calendar.date(bySettingHour: h, minute: 0, second: 0, of: time) ?? time
        return date.formatted(Date.FormatStyle(calendar: calendar).hour())
    }

    public var body: some View {
        HStack(spacing: 4) {
            ImpPicker("Hour", selection: Binding(get: { hour }, set: { set(hour: $0) }),
                      options: Array(0..<24), maxWidth: 110, title: hourName)
            Text(verbatim: ":").font(Typeface.label).foregroundStyle(Dungeon.muted)
            ImpPicker("Minute", selection: Binding(get: { minute }, set: { set(minute: $0) }),
                      options: minutes, maxWidth: 90) { String(format: "%02d", $0) }
        }
    }
}
