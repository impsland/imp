import SwiftUI

// Cards, rows and the small things that sit in them. Explanations live behind `InfoTip`s, so the
// pages stay short and the controls do the talking.

/// A small ⓘ that shows its text while you hover it (or click it). Every explanation goes here
/// instead of under the control it explains.
public struct InfoTip: View {
    let text: Text
    var symbol = "info.circle"
    @State private var hover = false
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    /// A finger needs the full hit target, a pointer is fine with the small glyph.
    private static var hitSide: CGFloat { Sizing.hit > 28 ? Sizing.hit : 18 }

    /// A literal is looked up in the String Catalog. Use `verbatim:` for a string that is shown as it is.
    public init(_ text: LocalizedStringKey, symbol: String = "info.circle") {
        self.text = Text(text)
        self.symbol = symbol
    }

    public init(verbatim text: String, symbol: String = "info.circle") {
        self.text = Text(verbatim: text)
        self.symbol = symbol
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hover || shown ? Dungeon.cream : Dungeon.muted.opacity(0.75))
            .frame(width: 18, height: 18)
            .frame(minWidth: Self.hitSide, minHeight: Self.hitSide)
            .contentShape(Circle())
            .onHover { inside in
                hover = inside
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(280))
                        if !Task.isCancelled { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                text
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(12)
            }
            .accessibilityElement()
            .accessibilityLabel("Info")
            .accessibilityValue(text)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Cards and rows

/// A stone tablet on the dungeon wall holding one group of settings: a one-line header (icon,
/// title, ⓘ, and an optional control on the right), then its content.
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
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
                            .accessibilityHidden(true)
                    }
                    Text(title).font(Typeface.cardTitle).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let info { InfoTip(info) }
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(minHeight: 26)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }
}

extension Card where Accessory == EmptyView {
    public init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// A labelled row: title (and ⓘ) on the left, its control on the right.
public struct Row<Control: View>: View {
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    var control: Control

    public init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.info = info
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Typeface.body).lineLimit(1)
            if let info { InfoTip(info) }
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: Sizing.hit)
    }
}

/// A form row whose label sits in a fixed column, so a card's controls line up.
public struct FieldRow<Control: View>: View {
    let label: LocalizedStringKey
    var info: LocalizedStringKey?
    var width: CGFloat
    var control: Control

    public init(_ label: LocalizedStringKey, info: LocalizedStringKey? = nil, width: CGFloat = 76, @ViewBuilder control: () -> Control) {
        self.label = label
        self.info = info
        self.width = width
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 3) {
                Text(label).font(Typeface.caption).foregroundStyle(Dungeon.muted).lineLimit(1)
                if let info { InfoTip(info) }
            }
            .frame(width: width, alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A hairline between rows in a card.
public struct CardDivider: View {
    public init() {}
    public var body: some View { Rectangle().fill(Dungeon.cardEdge).frame(height: 1).accessibilityHidden(true) }
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Dungeon.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }
}

private struct ListRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minHeight: Sizing.hit)
            .listRowBackground(Dungeon.card)
            .listRowSeparatorTint(Dungeon.cardEdge)
    }
}

extension View {
    /// The card surface (fill and soft edge) behind any view.
    public func impCard(radius: CGFloat = Radius.large) -> some View {
        modifier(CardSurface(radius: radius))
    }

    /// A row of a `List` in the app's look: card fill, soft separator and a comfortable height.
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
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                title.font(Typeface.label).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit)
            .background(Capsule().fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.1 : 0.06))))
            .overlay(Capsule().strokeBorder(picked ? Color.white.opacity(0.2) : Dungeon.cardEdge))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
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

    public init(text: LocalizedStringKey, symbol: String? = nil, color: Color = Dungeon.muted) {
        self.text = Text(text); self.symbol = symbol; self.color = color
    }

    /// For text that's already been localized or is data (an error from a server, say).
    public init(verbatim text: String, symbol: String? = nil, color: Color = Dungeon.muted) {
        self.text = Text(verbatim: text); self.symbol = symbol; self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
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

    public init(_ text: LocalizedStringKey, symbol: String, color: Color = Dungeon.muted) {
        self.text = Text(text)
        self.symbol = symbol
        self.color = color
    }

    public init(verbatim text: String, symbol: String, color: Color = Dungeon.muted) {
        self.text = Text(verbatim: text)
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(Typeface.small.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
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
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(isOn ? Color.white : Color.clear)
            .frame(width: 20, height: 20)
            .background(Circle().fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Dungeon.well)))
            .overlay(Circle().strokeBorder(isOn ? Color.white.opacity(0.25) : Dungeon.muted.opacity(0.7), lineWidth: 1.2))
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
        Button { withImpAnimation(Timing.quick, reduceMotion: reduceMotion) { isOn.toggle() } } label: {
            HStack(alignment: .top, spacing: 12) {
                SelectMark(isOn: isOn, tint: color)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOn ? 1 : 0.55)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(isOn ? AnyShapeStyle(color.opacity(0.12)) : AnyShapeStyle(Dungeon.card)))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(isOn ? color.opacity(0.65) : (hover ? Dungeon.muted.opacity(0.5) : Dungeon.cardEdge), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
