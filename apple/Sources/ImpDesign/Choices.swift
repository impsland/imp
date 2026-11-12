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
    private static var nudgeSize: CGSize { CGSize(width: Sizing.glyph, height: Sizing.control - Spacing.small) }
    #endif

    private var lower: Value { max(bounds.lowerBound, value.advanced(by: -step)) }
    private var upper: Value { min(bounds.upperBound, value.advanced(by: step)) }

    public var body: some View {
        HStack(spacing: Spacing.small) {
            label
                .font(Typeface.body.monospacedDigit())
                .foregroundStyle(Tone.text)
                .lineLimit(1)
            HStack(spacing: Spacing.hairline) {
                nudge("minus", "Less", to: lower, disabled: value <= bounds.lowerBound)
                nudge("plus", "More", to: upper, disabled: value >= bounds.upperBound)
            }
            .padding(Spacing.hairline)
            .background(Capsule().fill(Tone.card))
            .opacity(enabled ? 1 : Opacity.disabled)
        }
        .accessibilityRepresentation {
            Stepper(value: $value, in: bounds, step: step) { label }
        }
    }

    private func nudge(_ symbol: String, _ help: LocalizedStringKey, to target: Value, disabled: Bool) -> some View {
        Button { value = target } label: {
            Image(systemName: symbol)
                .font(.icon(.small, weight: .bold))
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
                    .foregroundStyle(Tone.text)
                    .background(Capsule().fill(configuration.isPressed ? Tone.line : (hover ? Tone.cardHover : Color.clear)))
                    .focusRing(Capsule(), shown: focused)
                    .contentShape(Capsule())
                    .opacity(enabled ? 1 : Opacity.disabled)
                    .onHover { hover = $0 && enabled }
            }
        }
    }
}

// MARK: - Segmented choice

/// Where a control sits, which decides its width.
enum ControlPlacement: Sendable {
    /// No row around it: a segmented bar fills the width it is given, a menu button keeps its own.
    case automatic
    /// On the same line as a title (a wide `Row`): every control keeps to its own width.
    case beside
    /// Under a title (a narrow `Row`): every control fills the width.
    case under
}

extension EnvironmentValues {
    /// Set by a `Row` for its control.
    @Entry var controlPlacement: ControlPlacement = .automatic
}

/// Lays the segments of a segmented bar out as equal columns: each is as wide as the widest segment
/// needs, and when the bar is given more room than that and `fills` is on, they share all of it. Its
/// own size is never less than the segments need, so a `ViewThatFits` around it only picks it when
/// every label fits its segment whole. Nothing in it can overlap, clip or leave its pill.
struct SegmentRow: Layout {
    var spacing: CGFloat
    var fills: Bool

    private func column(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func natural(_ subviews: Subviews) -> CGFloat {
        column(subviews) * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let need = natural(subviews)
        var width = need
        if fills, let offered = proposal.width, offered.isFinite, offered > need { width = offered }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return }
        let each = max(0, (bounds.width - spacing * (count - 1)) / count)
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + (each + spacing) * CGFloat(i), y: bounds.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: each, height: bounds.height))
        }
    }
}

/// A short row of choices in one pill, the chosen one lit in the Imp's colour. For a handful of
/// options seen at a glance (`SegmentedTabs` is the page-wide one). The segments are equal columns.
/// It always fits the width it is given: the words when they all fit their column, then icons (give
/// `symbol`, the titles become tooltips), and in the narrowest place a menu that shows the chosen
/// option. It never overlaps, clips or shrinks a label, at any width or text size.
///
/// Width: a bar beside its title (a wide `Row`) is only as wide as its columns. Anywhere else, under
/// a title, alone in a card or in a side panel, it fills the width it is given. `fills` overrides
/// that, for a bar placed in a line of other controls (`false`).
public struct ImpSegmented<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    let symbol: ((Value) -> String)?
    let fills: Bool?
    @Environment(\.impTint) private var tint
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlPlacement) private var placement
    @Namespace private var pill

    /// `label` names the whole control for VoiceOver. `title` names an option and is shown as is,
    /// so localize it first. `symbol` is an SF Symbol for an option, used when the words do not fit.
    /// `fills` forces the width: `true` spreads the columns over the whole row, `false` keeps them
    /// as narrow as their words. Leave it out and the placement decides (see above).
    public init(_ label: LocalizedStringKey, selection: Binding<Value>, options: [Value],
                title: @escaping (Value) -> String, symbol: ((Value) -> String)? = nil, fills: Bool? = nil) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
        self.symbol = symbol
        self.fills = fills
    }

    private var fillsRow: Bool { fills ?? (placement != .beside) }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            bar { Text(verbatim: title($0)).font(Typeface.label).lineLimit(1).fixedSize(horizontal: true, vertical: false) }
            if let symbol {
                bar { Image(systemName: symbol($0)).font(.icon(.large)).help(title($0)) }
            }
            ImpPicker(label, selection: $selection, options: options, symbol: symbol?(selection), title: title)
                .environment(\.controlPlacement, fillsRow ? .under : .beside)
        }
        .opacity(enabled ? 1 : Opacity.disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func bar<Face: View>(@ViewBuilder face: @escaping (Value) -> Face) -> some View {
        SegmentRow(spacing: Spacing.hairline, fills: fillsRow) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    withImpAnimation(Motion.smooth, reduceMotion: reduceMotion) { selection = option }
                } label: {
                    face(option)
                        .foregroundStyle(on ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
                        .padding(.horizontal, Spacing.medium)
                        .frame(maxWidth: .infinity, minHeight: Sizing.hit - Spacing.hairline * 2)
                        .frame(minWidth: Sizing.control)
                        .background {
                            if on {
                                Capsule().fill(TintFill(tint)).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Spacing.hairline)
        .background(Capsule().fill(Tone.well))
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
                    .font(Typeface.label)
                    .lineLimit(1)
                    .foregroundStyle(on ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                    .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.tight)
                    .frame(minHeight: Sizing.control - Spacing.tight)
                    .background(Capsule().fill(on ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.cardHover : Tone.card)))
                    .focusRing(Capsule(), shown: focused)
                    .contentShape(Capsule())
                    .opacity(enabled ? 1 : Opacity.disabled)
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
        HStack(spacing: Spacing.tight) {
            ImpPicker("Hour", selection: Binding(get: { hour }, set: { set(hour: $0) }),
                      options: Array(0..<24), title: hourName)
            Text(verbatim: ":").font(Typeface.label).foregroundStyle(Tone.muted)
            ImpPicker("Minute", selection: Binding(get: { minute }, set: { set(minute: $0) }),
                      options: minutes) { String(format: "%02d", $0) }
        }
    }
}
