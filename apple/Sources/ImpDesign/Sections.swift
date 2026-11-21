import SwiftUI

// The sections of a settings screen, always one tap away: a rail down the leading edge when there is
// room (a desktop window, a wide screen), a bar across the top when there is not (a phone, a narrow
// window). A bar of a few sections fills its width in equal parts (`fills`), and many scroll sideways. Picking a section swaps the content beside or below it,
// so nobody goes back to a list to reach the next one.

/// One section of a `SectionRail`: an icon, one or two plain words, and whether something in it
/// needs a look.
public struct SectionItem<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public let title: String
    public let symbol: String
    public var needsAttention: Bool

    /// `title` is shown as it is, so localize it first. `symbol` is an SF Symbol.
    public init(id: ID, title: String, symbol: String, needsAttention: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.needsAttention = needsAttention
    }
}

/// The sections of a settings screen as a rail (`.vertical`) or a bar (`.horizontal`). The chosen
/// one is filled with the tint, the others are quiet until pointed at. `compact` shows the icons
/// alone (the titles become the tooltips and the spoken labels), for a rail in a narrow window. `fills`
/// shares a horizontal bar's width evenly between the sections, with their titles while they fit and
/// their icons alone when they do not: one track, the pick lit in the tint.
/// A section that needs a look carries a small mark, spoken as `common.needs_attention`.
public struct SectionRail<ID: Hashable & Sendable>: View {
    let label: LocalizedStringKey
    let items: [SectionItem<ID>]
    @Binding var selection: ID
    let axis: Axis
    let compact: Bool
    let fills: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `label` names the whole control for VoiceOver.
    public init(_ label: LocalizedStringKey, items: [SectionItem<ID>], selection: Binding<ID>,
                axis: Axis = .vertical, compact: Bool = false, fills: Bool = false) {
        self.label = label
        self.items = items
        _selection = selection
        self.axis = axis
        self.compact = compact
        self.fills = fills
    }

    public var body: some View {
        Group {
            switch axis {
            case .vertical:
                VStack(alignment: .leading, spacing: Spacing.tight) { buttons }
            case .horizontal where fills:
                // Titles while all of them fit side by side, icons alone when they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.tight) { buttons(compact: false) }
                    HStack(spacing: Spacing.tight) { buttons(compact: true) }
                }
                .padding(Spacing.tight)
                .background(Capsule().fill(Tone.card))
                .padding(.horizontal, Spacing.page)
            case .horizontal:
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.snug) { buttons }
                            .padding(.horizontal, Spacing.page)
                    }
                    .onChange(of: selection, initial: true) { _, chosen in
                        withImpAnimation(Motion.smooth, reduceMotion: reduceMotion) { proxy.scrollTo(chosen, anchor: .center) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var buttons: some View { buttons(compact: compact) }

    private func buttons(compact: Bool) -> some View {
        ForEach(items) { item in
            Button {
                withImpAnimation(Motion.smooth, reduceMotion: reduceMotion) { selection = item.id }
            } label: {
                SectionFace(item: item, chosen: item.id == selection, axis: axis, compact: compact,
                            fills: fills && axis == .horizontal)
            }
            .buttonStyle(SectionStyle())
            .id(item.id)
            .help(compact || fills ? item.title : "")
            .accessibilityLabel(item.title)
            .accessibilityValue(item.needsAttention ? Text("common.needs_attention") : Text(verbatim: ""))
            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
            .accessibilityIdentifier("section.\(String(describing: item.id))")
        }
    }
}

/// An icon and its title in a pebble: the tint when chosen, a soft fill under the pointer.
private struct SectionFace<ID: Hashable & Sendable>: View {
    let item: SectionItem<ID>
    let chosen: Bool
    let axis: Axis
    let compact: Bool
    /// A part of a bar that fills its width: as wide as the others, its icon and title centred, on the bar's track.
    var fills = false
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    /// The pebble under the face: the tint when chosen. On a filled bar the rest sit on its track.
    private var fill: AnyShapeStyle {
        if chosen { return AnyShapeStyle(TintFill(tint)) }
        if hover { return AnyShapeStyle(Tone.cardHover) }
        return AnyShapeStyle(Tone.card.opacity(axis == .horizontal && !fills ? 1 : 0))
    }

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: item.symbol)
                .font(.icon(.large))
                .frame(width: Sizing.iconTile, height: Sizing.iconTile)
                .overlay(alignment: .topTrailing) {
                    if item.needsAttention {
                        Circle().fill(chosen ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.warnText))
                            .frame(width: Sizing.dot, height: Sizing.dot)
                    }
                }
            if !compact {
                Text(verbatim: item.title).font(Typeface.label).lineLimit(1).fixedSize()
                if axis == .vertical { Spacer(minLength: 0) }
            }
        }
        .foregroundStyle(chosen ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(hover ? Tone.text : Tone.muted))
        .padding(.horizontal, compact ? Spacing.tight : Spacing.cozy)
        .padding(.vertical, Spacing.tight)
        .frame(minWidth: Sizing.hit, minHeight: Sizing.hit)
        .frame(maxWidth: fills || (axis == .vertical && !compact) ? .infinity : nil, alignment: fills ? .center : .leading)
        .background(Capsule().fill(fill))
        .focusRing(Capsule(), shown: focused)
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .impAnimation(Motion.hover, value: hover)
    }
}

private struct SectionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Opacity.dimmed : 1)
            .impAnimation(Motion.press, value: configuration.isPressed)
    }
}
