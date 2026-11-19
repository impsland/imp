import SwiftUI

// Text fields, editors, switches and sliders in the app's look. Each is the standard control
// underneath, so focus, selection, the keyboard and VoiceOver behave as they do everywhere.

// MARK: - Fields

/// Text fields and editors in the window's style: a well with no outline. A ring in the Imp's
/// colour shows while you type.
private struct FieldChrome: ViewModifier {
    var mono = false
    var large = false
    var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Typeface.mono : (large ? Typeface.cardTitle.weight(.regular) : Typeface.body))
            .focused($focused)
            .padding(.leading, Spacing.cozy)
            .padding(.trailing, problem == nil ? Spacing.cozy : Sizing.iconTile)
            .frame(minHeight: large ? Sizing.control + Spacing.tight : Sizing.control)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(problem == nil ? tint : Tone.danger, lineWidth: Stroke.focus).opacity(focused || problem != nil ? 1 : 0))
            // What is wrong sits inside the well, at its trailing edge: the field is no taller for it, and
            // nothing under the field is held free in case it comes.
            .overlay(alignment: .trailing) {
                if let problem {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.icon(.medium))
                        .foregroundStyle(Tone.danger)
                        .frame(width: Sizing.iconTile)
                        .help(problem)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .accessibilityHint(problem.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .opacity(enabled ? 1 : Opacity.disabled)
            .impAnimation(value: focused)
            .impAnimation(value: problem)
    }
}

extension View {
    /// Dresses a `TextField` or `SecureField` in the app's field look. Use it on the field itself.
    /// `problem`: what is wrong with the value, shown in the field itself (a red ring and a mark that says
    /// it on hover) instead of in a line under it. Give the field a prompt that says it too, so it reads
    /// without the pointer.
    public func impField(mono: Bool = false, large: Bool = false, problem: String? = nil) -> some View {
        modifier(FieldChrome(mono: mono, large: large, problem: problem))
    }
}

/// A field and the actions that act on its value, as one control: the well holds an optional leading
/// symbol, the field, and quiet `FieldAction`s at its trailing edge. The one pattern for an input with an
/// action (choose a model, show or paste a key, clear a search): never a separate button beside a field,
/// whose capsule would clash with the well's corners. An action of the page (New, Add) is not on the
/// field's line: it goes in the header of the card or list.
public struct FieldWell<Field: View, Actions: View>: View {
    let symbol: String?
    let mono: Bool
    let field: Field
    let actions: Actions
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    public init(symbol: String? = nil, mono: Bool = false, @ViewBuilder field: () -> Field, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.mono = mono
        self.field = field()
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: Spacing.tight) {
            if let symbol {
                Image(systemName: symbol).font(.icon(.medium, weight: .semibold)).foregroundStyle(Tone.muted)
                    .accessibilityHidden(true)
            }
            field
                .textFieldStyle(.plain)
                .font(mono ? Typeface.mono : Typeface.body)
                .focused($focused)
                .frame(maxWidth: .infinity)
            actions
        }
        .padding(.leading, Spacing.cozy)
        .padding(.trailing, Spacing.tight)
        .frame(minHeight: Sizing.control)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .strokeBorder(tint, lineWidth: Stroke.focus).opacity(focused ? 1 : 0))
        .impAnimation(value: focused)
    }
}

extension FieldWell where Actions == EmptyView {
    /// A field with a leading symbol and no actions (a search before anything is typed).
    public init(symbol: String? = nil, mono: Bool = false, @ViewBuilder field: () -> Field) {
        self.init(symbol: symbol, mono: mono, field: field) { EmptyView() }
    }
}

/// An action inside a `FieldWell`: a quiet glyph whose hover shape follows the well's corners, inset
/// by `Spacing.tight` (so the corners stay concentric). Always give it a `help`.
public struct FieldAction: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    public init(systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(FieldActionStyle(systemName: systemName))
            .help(help)
            .accessibilityLabel(help)
    }

    /// The inner corner: the well's, less the inset.
    static var radius: CGFloat { max(Radius.small - Spacing.tight, 0) }
    /// As tall as the well, less the inset above and below.
    static var side: CGFloat { Sizing.control - Spacing.tight * 2 }
}

private struct FieldActionStyle: ButtonStyle {
    let systemName: String
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: FieldAction.radius, style: .continuous)
        Image(systemName: systemName)
            .font(.icon(.medium, weight: .semibold))
            .foregroundStyle(hover || configuration.isPressed ? Tone.text : Tone.muted)
            .frame(width: FieldAction.side, height: FieldAction.side)
            .background(shape.fill(configuration.isPressed ? Tone.line : (hover ? Tone.cardHover : Color.clear)))
            .focusRing(shape, shown: focused)
            .contentShape(shape)
            .opacity(enabled ? 1 : Opacity.disabled)
            .onHover { hover = $0 && enabled }
            .impAnimation(Motion.quick, value: hover)
    }
}

/// A multi-line well, with a placeholder. With no `height` it fills the room it is given.
public struct EditorWell: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey?
    var codePlaceholder: String
    var mono: Bool
    var height: CGFloat?
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    /// `codePlaceholder` is a placeholder that is code or a format, shown as it is.
    public init(text: Binding<String>, placeholder: LocalizedStringKey? = nil, codePlaceholder: String = "",
                mono: Bool = false, height: CGFloat? = 90) {
        _text = text
        self.placeholder = placeholder
        self.codePlaceholder = codePlaceholder
        self.mono = mono
        self.height = height
    }

    private var font: Font { mono ? Typeface.mono : Typeface.body }

    public var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.snug)
            .frame(minHeight: height, maxHeight: height ?? .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(tint, lineWidth: Stroke.focus).opacity(focused ? 1 : 0))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    (placeholder.map { Text($0) } ?? Text(verbatim: codePlaceholder))
                        .font(font)
                        .foregroundStyle(Tone.faint)
                        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
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
        @State private var hover = false

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: Spacing.cozy) {
                    if labelled {
                        configuration.label
                        Spacer(minLength: Spacing.small)
                    }
                    track
                }
                .frame(minHeight: Sizing.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : Opacity.disabled)
            .onHover { hover = $0 && enabled }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private var track: some View {
            let on = configuration.isOn
            return Capsule()
                .fill(on ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.line : Tone.cardHover))
                .frame(width: Sizing.switchTrack, height: Sizing.mark + Spacing.tight)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(on ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted)).padding(Spacing.tight)
                        .frame(width: Sizing.mark + Spacing.tight, height: Sizing.mark + Spacing.tight)
                }
                .focusRing(Capsule(), shown: focused)
                .impAnimation(Motion.quick, value: on)
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
        HStack(spacing: Spacing.hairline) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button { withImpAnimation(Motion.smooth, reduceMotion: reduceMotion) { selection = tab } } label: {
                    HStack(spacing: Spacing.snug) {
                        Image(systemName: tab[keyPath: icon]).font(.icon(.medium))
                        Text(tab[keyPath: title]).font(Typeface.label).lineLimit(1)
                        if badge(tab) { Circle().fill(Tone.accent).frame(width: Spacing.snug, height: Spacing.snug) }
                    }
                    .foregroundStyle(on ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
                    .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                    .background {
                        if on {
                            Capsule().fill(TintFill(tint)).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab[keyPath: title])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Spacing.hairline)
        .background(Capsule().fill(Tone.well))
    }
}
