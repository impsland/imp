import SwiftUI

/// What an empty list shows, the same everywhere: its picture, then one short line under it, centred.
/// `fills` centres it in the room the page has left (a list that is the whole page). Without it, it sits in
/// the middle of its card.
public struct EmptyState: View {
    let text: Text
    let symbol: String
    var fills: Bool

    public init(_ text: LocalizedStringKey, symbol: String, fills: Bool = false) {
        self.text = Text(text); self.symbol = symbol; self.fills = fills
    }

    public var body: some View {
        let content = VStack(spacing: Spacing.small) {
            Image(systemName: symbol)
                .font(.icon(.huge, weight: .light))
                .foregroundStyle(Tone.faint)
                .accessibilityHidden(true)
            text
                .font(Typeface.body).foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.large)
        .accessibilityElement(children: .combine)
        if fills {
            // The scroll view's height less the room of a list header above it, so it sits in the middle of the page.
            content.containerRelativeFrame(.vertical, alignment: .center) { height, _ in max(height - Sizing.control * 3, Sizing.control * 4) }
        } else {
            content
        }
    }
}
