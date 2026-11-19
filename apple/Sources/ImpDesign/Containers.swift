import SwiftUI

// Cards, rows and the small things that sit in them. Explanations live behind `InfoTip`s, so the
// pages stay short and the controls do the talking.

// MARK: - Cards and rows

/// A pebble holding one group of settings: a one-line header (icon, title, help, and an optional
/// control on the right), then its content. It is a soft fill with no outline, and its rows are
/// set apart by space, never by lines.
public struct Card<Content: View, Accessory: View>: View {
    var title: LocalizedStringKey?
    var icon: String?
    var info: LocalizedStringKey?
    var accessory: Accessory
    var content: Content
    @Environment(\.impTint) private var tint

    public init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let title {
                SectionHeader(title, icon: icon, info: info) { accessory }
            }
            content
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Tone.card))
    }
}

/// The header of a card, a section or a sheet: the leading edge holds the picture and the title, the
/// trailing edge holds an optional control and then the help tip, always last, so the header is balanced
/// and the question mark is in the same place everywhere. A row with its own control is not a header.
public struct SectionHeader<Leading: View, Accessory: View>: View {
    var tip: InfoTip?
    var minHeight: CGFloat?
    var leading: Leading
    var accessory: Accessory

    /// A header with any leading content (a disclosure button, a tinted glyph).
    public init(info: LocalizedStringKey? = nil, verbatimInfo: String? = nil, minHeight: CGFloat? = Sizing.iconTile,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder leading: () -> Leading) {
        self.tip = info.map { InfoTip($0) } ?? verbatimInfo.map { InfoTip(verbatim: $0) }
        self.minHeight = minHeight
        self.leading = leading()
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: Spacing.small) {
            leading
            Spacer(minLength: Spacing.small)
            accessory
            if let tip { tip }
        }
        .frame(minHeight: minHeight)
    }
}

/// The icon tile and the title of a `SectionHeader`.
public struct HeaderTitle: View {
    var title: Text
    var icon: String?
    var font: Font
    var color: Color

    public var body: some View {
        HStack(spacing: Spacing.small) {
            if let icon { IconTile(systemName: icon) }
            title.font(font).foregroundStyle(color).lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }
}

extension SectionHeader where Leading == HeaderTitle {
    public init(_ title: LocalizedStringKey, icon: String? = nil, info: LocalizedStringKey? = nil,
                font: Font = Typeface.cardTitle, color: Color = Tone.text, minHeight: CGFloat? = Sizing.iconTile,
                @ViewBuilder accessory: () -> Accessory) {
        self.init(info: info, minHeight: minHeight, accessory: accessory) {
            HeaderTitle(title: Text(title), icon: icon, font: font, color: color)
        }
    }

    public init(verbatim title: String, icon: String? = nil, info: LocalizedStringKey? = nil,
                font: Font = Typeface.cardTitle, color: Color = Tone.text, minHeight: CGFloat? = Sizing.iconTile,
                @ViewBuilder accessory: () -> Accessory) {
        self.init(info: info, minHeight: minHeight, accessory: accessory) {
            HeaderTitle(title: Text(verbatim: title), icon: icon, font: font, color: color)
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    public init(info: LocalizedStringKey? = nil, verbatimInfo: String? = nil, minHeight: CGFloat? = Sizing.iconTile,
                @ViewBuilder leading: () -> Leading) {
        self.init(info: info, verbatimInfo: verbatimInfo, minHeight: minHeight, accessory: { EmptyView() }, leading: leading)
    }
}

extension SectionHeader where Leading == HeaderTitle, Accessory == EmptyView {
    public init(_ title: LocalizedStringKey, icon: String? = nil, info: LocalizedStringKey? = nil,
                font: Font = Typeface.cardTitle, color: Color = Tone.text, minHeight: CGFloat? = Sizing.iconTile) {
        self.init(title, icon: icon, info: info, font: font, color: color, minHeight: minHeight) { EmptyView() }
    }
}

extension Card where Accessory == EmptyView {
    public init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// One setting: its picture, its title and its help on the leading edge, its control on the
/// trailing edge. When the title and the control do not fit side by side, the control moves to a
/// line of its own under the title, so nothing overlaps or is cut short. A control under its title
/// fills the row (a segmented bar becomes equal columns across it, a menu button stretches). A control
/// beside the title keeps to its own width.
public struct Row<Control: View>: View {
    let title: LocalizedStringKey
    var icon: String?
    var info: LocalizedStringKey?
    var control: Control

    public init(_ title: LocalizedStringKey, icon: String? = nil, info: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.icon = icon
        self.info = info
        self.control = control()
    }

    private var heading: some View {
        HStack(spacing: Spacing.snug) {
            if let icon {
                Image(systemName: icon).font(.icon(.large)).foregroundStyle(Tone.muted)
                    .frame(width: Sizing.mark).accessibilityHidden(true)
            }
            Text(title).font(Typeface.body).lineLimit(1).fixedSize()
            if let info { InfoTip(info) }
        }
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.snug) {
                heading
                Spacer(minLength: Spacing.medium)
                control.environment(\.controlPlacement, .beside)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                heading
                control.environment(\.controlPlacement, .under).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: Sizing.hit)
    }
}

/// The widest label of the `FieldRow`s in a form, so every field starts at the same x whatever the words are
/// (a longer word in another language widens the column for all rows instead of pushing one field over).
private struct FieldLabelWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct FieldLabelColumn: ViewModifier {
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .environment(\.fieldLabelColumn, width)
            .onPreferenceChange(FieldLabelWidth.self) { width = $0 }
    }
}

extension EnvironmentValues {
    /// The label column the `FieldRow`s of a form share (see `View.fieldLabelColumn()`).
    @Entry var fieldLabelColumn: CGFloat = 0
}

extension View {
    /// Makes the `FieldRow`s inside share one label column: as wide as the widest label, never less than
    /// `Sizing.fieldLabel`, so all their fields start at the same x.
    public func fieldLabelColumn() -> some View { modifier(FieldLabelColumn()) }
}

/// A form row whose label sits in a fixed column, so a card's controls line up. Inside `fieldLabelColumn()`
/// the rows share the widest label's width.
public struct FieldRow<Control: View>: View {
    let label: LocalizedStringKey
    var info: LocalizedStringKey?
    var width: CGFloat
    var control: Control
    @Environment(\.fieldLabelColumn) private var column

    public init(_ label: LocalizedStringKey, info: LocalizedStringKey? = nil, width: CGFloat = Sizing.fieldLabel, @ViewBuilder control: () -> Control) {
        self.label = label
        self.info = info
        self.width = width
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.hairline) {
                Text(label).font(Typeface.caption).foregroundStyle(Tone.muted).lineLimit(1).fixedSize()
                if let info { InfoTip(info) }
            }
            // What this label needs, before the column is applied: the form's column is the widest of them.
            .background(GeometryReader { Color.clear.preference(key: FieldLabelWidth.self, value: $0.size.width) })
            // The column is `width` wide, and grows for a longer word in another language instead of cutting it short.
            .frame(minWidth: max(width, column), alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Tone.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct ListRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minHeight: Sizing.hit)
            .listRowBackground(Tone.card)
            .listRowSeparator(.hidden)
    }
}

extension View {
    /// The pebble (a soft fill, no outline) behind any view.
    public func impCard(radius: CGFloat = Radius.large) -> some View {
        modifier(CardSurface(radius: radius))
    }

    /// A row of a `List` in the app's look: a soft fill, no separator and a comfortable height.
    public func impListRow() -> some View {
        modifier(ListRowChrome())
    }
}

// MARK: - Chips and badges

/// Chips you pick one of (ideas, templates, hints), in the window's style.
public struct ChoiceChip: View {
    let title: Text
    var icon: String?
    let picked: Bool
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    public init(title: LocalizedStringKey, icon: String? = nil, picked: Bool, action: @escaping () -> Void) {
        self.title = Text(title); self.icon = icon; self.picked = picked; self.action = action
    }

    /// For names and other text that's data, not interface.
    public init(verbatim title: String, icon: String? = nil, picked: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: title); self.icon = icon; self.picked = picked; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.snug) {
                if let icon { Image(systemName: icon).font(.icon(.medium)) }
                title.font(Typeface.label).lineLimit(1)
            }
            .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
            .padding(.horizontal, Spacing.cozy)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit)
            .background(Capsule().fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.cardHover : Tone.card)))
            .focusRing(Capsule(), shown: focused)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .impAnimation(value: hover)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A status line in the window's voice: a coloured dot or symbol and a few words.
public struct StatusText: View {
    let text: Text
    var symbol: String?
    var color: Color

    public init(text: LocalizedStringKey, symbol: String? = nil, color: Color = Tone.muted) {
        self.text = Text(text); self.symbol = symbol; self.color = color
    }

    /// For text that's already been localized or is data (an error from a server, say).
    public init(verbatim text: String, symbol: String? = nil, color: Color = Tone.muted) {
        self.text = Text(verbatim: text); self.symbol = symbol; self.color = color
    }

    public var body: some View {
        HStack(spacing: Spacing.snug) {
            if let symbol { Image(systemName: symbol).font(.icon(.small)) }
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(Typeface.small)
        .foregroundStyle(color)
    }
}

/// A small pill: a symbol and a few words, in a colour.
public struct Badge: View {
    let text: Text
    let symbol: String
    var color: Color

    public init(_ text: LocalizedStringKey, symbol: String, color: Color = Tone.muted) {
        self.text = Text(text)
        self.symbol = symbol
        self.color = color
    }

    public init(verbatim text: String, symbol: String, color: Color = Tone.muted) {
        self.text = Text(verbatim: text)
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: symbol).font(.icon(.small))
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(Typeface.small.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
        .background(Capsule().fill(color.opacity(Opacity.tintFill)))
    }
}

/// A round tick: filled in the colour when on.
public struct SelectMark: View {
    let isOn: Bool
    var tint: Color

    public init(isOn: Bool, tint: Color) {
        self.isOn = isOn
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.icon(.small, weight: .heavy))
            .foregroundStyle(isOn ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Color.clear))
            .frame(width: Sizing.mark, height: Sizing.mark)
            .background(Circle().fill(isOn ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.cardHover)))
    }
}

/// A card you tick as a whole: the mark on the left, the content dimmed while it's left out.
public struct SelectableCard<Content: View>: View {
    @Binding var isOn: Bool
    var tint: Color?
    var content: Content
    @Environment(\.impTint) private var inherited
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    public init(isOn: Binding<Bool>, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        _isOn = isOn
        self.tint = tint
        self.content = content()
    }

    private var color: Color { tint ?? inherited }

    public var body: some View {
        Button { withImpAnimation(Motion.quick, reduceMotion: reduceMotion) { isOn.toggle() } } label: {
            HStack(alignment: .top, spacing: Spacing.medium) {
                SelectMark(isOn: isOn, tint: color)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOn ? 1 : Opacity.dimmed)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(isOn ? AnyShapeStyle(color.opacity(Opacity.tintFill)) : AnyShapeStyle(hover ? Tone.cardHover : Tone.card)))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What needs fixing on the page it heads (spec `attention`). It sits at the top of the settings
/// section that fixes it, so the person reads it where they act on it. Each problem is one calm pebble,
/// not a coloured block: a picture of what it is about, lit in the warning colour, one short line, and the
/// way to fix it as a button on the trailing side when the fix is elsewhere. Nothing shows when the list
/// is empty.
public struct AttentionNotice: View {
    /// One problem: what it is about (a symbol), what is wrong, and the way to fix it, if any.
    public struct Line: Identifiable {
        public var id: String
        public var symbol: String
        public var text: String
        public var fix: Fix?

        public init(id: String, symbol: String, text: String, fix: Fix? = nil) {
            self.id = id; self.symbol = symbol; self.text = text; self.fix = fix
        }
    }

    /// The button that fixes a problem: a word or two and its picture.
    public struct Fix {
        public var title: LocalizedStringKey
        public var symbol: String
        public var action: () -> Void

        public init(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) {
            self.title = title; self.symbol = symbol; self.action = action
        }
    }

    let lines: [Line]

    public init(_ lines: [Line]) { self.lines = lines }

    public var body: some View {
        if !lines.isEmpty {
            VStack(spacing: Spacing.snug) {
                ForEach(lines) { line in row(line) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("common.needs_attention"))
        }
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: line.symbol)
                .font(.icon(.medium, weight: .semibold))
                .foregroundStyle(Tone.warnText)
                .frame(width: Sizing.iconTile, height: Sizing.iconTile)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.warnBackground))
                .accessibilityHidden(true)
            Text(verbatim: line.text).font(Typeface.label).foregroundStyle(Tone.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let fix = line.fix {
                Button(action: fix.action) { FitLabel(fix.title, systemImage: fix.symbol) }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }
        .padding(Spacing.cozy)
        .frame(minHeight: Sizing.hit)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.card))
        .accessibilityElement(children: line.fix == nil ? .combine : .contain)
    }
}
