import SwiftUI

/// One emoji per choice, all on a single line that shares the width evenly: a compact pick of presets (an Imp's
/// character) on the Mac and the iPhone alike. The picked one sits on a filled circle in the tint. Each emoji is
/// named for VoiceOver and, on the Mac, on hover.
public struct EmojiRow<ID: Hashable>: View {
    public struct Item: Identifiable {
        public var id: ID
        public var emoji: String
        public var name: String

        public init(id: ID, emoji: String, name: String) {
            self.id = id; self.emoji = emoji; self.name = name
        }
    }

    let label: LocalizedStringKey
    let items: [Item]
    let picked: ID?
    let pick: (ID) -> Void

    public init(_ label: LocalizedStringKey, items: [Item], picked: ID?, pick: @escaping (ID) -> Void) {
        self.label = label; self.items = items; self.picked = picked; self.pick = pick
    }

    public var body: some View {
        HStack(spacing: Spacing.hairline) {
            ForEach(items) { item in
                EmojiChoice(item: item, picked: item.id == picked) { pick(item.id) }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

private struct EmojiChoice<ID: Hashable>: View {
    let item: EmojiRow<ID>.Item
    let picked: Bool
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: item.emoji)
                .font(Typeface.cardTitle)
                .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                // A circle as big as the cell's narrower side, so the row still fits a narrow phone.
                .background {
                    Circle().fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.cardHover : Color.clear))
                        .aspectRatio(1, contentMode: .fit)
                }
                .focusRing(Circle(), shown: focused)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(Text(verbatim: item.name))
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityIdentifier("emoji.\(String(describing: item.id))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
