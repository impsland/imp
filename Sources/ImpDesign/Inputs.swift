import SwiftUI

// Text fields, editors, switches and sliders in the app's look. Each is the standard control
// underneath, so focus, selection, the keyboard and VoiceOver behave as they do everywhere.

// MARK: - Fields

/// Text fields and editors in the window's style: a dark well with a soft edge that lights up
/// in the Imp's colour while you type.
private struct FieldChrome: ViewModifier {
    var mono = false
    var large = false
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Typeface.mono : (large ? .system(size: 14) : Typeface.body))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: large ? max(34, Sizing.control) : Sizing.control)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Dungeon.well))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.85) : Dungeon.cardEdge, lineWidth: focused ? 1.5 : 1))
            .impAnimation(value: focused)
    }
}

extension View {
    /// Dresses a `TextField` or `SecureField` in the app's field look. Use it on the field itself.
    public func impField(mono: Bool = false, large: Bool = false) -> some View {
        modifier(FieldChrome(mono: mono, large: large))
    }
}

/// A multi-line well, with a placeholder.
public struct EditorWell: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey?
    var codePlaceholder: String
    var mono: Bool
    var height: CGFloat
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    /// `codePlaceholder` is a placeholder that is code or a format, shown as it is.
    public init(text: Binding<String>, placeholder: LocalizedStringKey? = nil, codePlaceholder: String = "",
                mono: Bool = false, height: CGFloat = 90) {
        _text = text
        self.placeholder = placeholder
        self.codePlaceholder = codePlaceholder
        self.mono = mono
        self.height = height
    }

    private var font: Font { mono ? .system(size: 12, design: .monospaced) : Typeface.body }

    public var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 7)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dungeon.well))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.85) : Dungeon.cardEdge, lineWidth: focused ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    (placeholder.map { Text($0) } ?? Text(verbatim: codePlaceholder))
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .impAnimation(value: focused)
    }
}

// MARK: - Switch

/// A switch in the app's look: a capsule track in the Imp's colour with a round thumb. It is
/// still a real `Toggle`, so VoiceOver reads it as a switch and the keyboard works as usual.
public struct ImpSwitchStyle: ToggleStyle {
    var labelled: Bool

    /// With `labelled: false` only the switch shows, sized to itself, for a row that has its own
    /// title. VoiceOver still reads the toggle's label.
    public init(labelled: Bool = true) { self.labelled = labelled }

    public func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration, labelled: labelled)
    }

    private struct Switch: View {
        let configuration: Configuration
        let labelled: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.impTint) private var tint
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hover = false

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    if labelled {
                        configuration.label
                        Spacer(minLength: 8)
                    }
                    track
                }
                .frame(minHeight: Sizing.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hover = $0 && enabled }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private var track: some View {
            let on = configuration.isOn
            return Capsule()
                .fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.22 : 0.16)))
                .frame(width: 42, height: 24)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Color.white).padding(2.5)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: 24, height: 24)
                }
                .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
                .animation(reduceMotion ? nil : Timing.quick, value: on)
        }
    }
}

extension ToggleStyle where Self == ImpSwitchStyle {
    /// The app's switch.
    public static var impSwitch: ImpSwitchStyle { ImpSwitchStyle() }
    /// The app's switch without its label, for a row that already has a title.
    public static var impSwitchBare: ImpSwitchStyle { ImpSwitchStyle(labelled: false) }
}

// MARK: - Slider

private struct SliderChrome: ViewModifier {
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        content
            .tint(tint)
            .frame(minHeight: Sizing.hit)
    }
}

extension View {
    /// Tints a `Slider` in the Imp's colour and gives it a comfortable height to grab.
    public func impSlider() -> some View {
        modifier(SliderChrome())
    }
}

// MARK: - Segmented

/// A segmented bar of tabs as wide as the page: icon and title side by side, the chosen one
/// lit in the Imp's colour, sliding from tab to tab.
public struct SegmentedTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: KeyPath<Tab, String>
    let icon: KeyPath<Tab, String>
    var badge: (Tab) -> Bool
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    public init(tabs: [Tab], selection: Binding<Tab>, title: KeyPath<Tab, String>, icon: KeyPath<Tab, String>,
                badge: @escaping (Tab) -> Bool = { _ in false }) {
        self.tabs = tabs
        _selection = selection
        self.title = title
        self.icon = icon
        self.badge = badge
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button { withImpAnimation(.snappy(duration: Timing.medium), reduceMotion: reduceMotion) { selection = tab } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab[keyPath: icon]).font(.system(size: 12, weight: .semibold))
                        Text(tab[keyPath: title]).font(Typeface.label).lineLimit(1)
                        if badge(tab) { Circle().fill(.orange).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(on ? Color.white : Dungeon.muted)
                    .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                    .background {
                        if on {
                            Capsule().fill(tint.gradient).matchedGeometryEffect(id: "pill", in: pill)
                                .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab[keyPath: title])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Dungeon.card))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
    }
}
