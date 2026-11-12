import SwiftUI

/// The quiet bar that offers to take back a quick change (an Imp let out, sent home or hidden).
/// It shows over the bottom of the screen and goes away by itself. The caller decides when.
public struct UndoBar: View {
    let message: String
    let undoTitle: LocalizedStringKey
    let undo: () -> Void

    public init(message: String, undoTitle: LocalizedStringKey, undo: @escaping () -> Void) {
        self.message = message
        self.undoTitle = undoTitle
        self.undo = undo
    }

    public var body: some View {
        HStack(spacing: Spacing.medium) {
            Text(message)
                .font(Typeface.body)
                .foregroundStyle(Tone.text)
                .lineLimit(2)
            Button(action: undo) { Text(undoTitle) }
                .buttonStyle(.imp(.secondary, small: true))
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.small)
        .background(Capsule().fill(Tone.raised))
        .shadow(color: Elevation.cardColor, radius: Spacing.small, y: Spacing.tight)
        .accessibilityElement(children: .contain)
    }
}

/// The small phone beside the name of an Imp that is on a phone. The phone is never drawn on the Imp.
public struct PhoneBadge: View {
    let label: String

    public init(label: String) { self.label = label }

    public var body: some View {
        Image(systemName: "iphone")
            .font(.icon(.medium))
            .foregroundStyle(Tone.muted)
            .help(Text(label))
            .accessibilityLabel(Text(label))
    }
}
