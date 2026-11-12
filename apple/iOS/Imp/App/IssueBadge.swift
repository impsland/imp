import ImpDesign
import SwiftUI

/// What's wrong (or worth knowing) about something, kept out of the way: a small icon next to it,
/// whose words open in a popover on the app surface when you tap it. The app never spells problems
/// out inline.
struct IssueBadge: View {
    enum Kind {
        /// Something to fix before it works.
        case problem
        /// A tip: nothing's wrong.
        case info
    }

    var text: String
    var kind: Kind = .problem
    /// Opens the popover as soon as it appears (for a problem you just caused, like a bad paste).
    var opensAtOnce = false
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: kind == .problem ? "exclamationmark.circle.fill" : "info.circle")
                .font(.icon(.big))
                .foregroundStyle(kind == .problem ? Tone.accentBright : Tone.muted)
                .symbolEffect(.bounce, value: text)
                .frame(width: Sizing.hit, height: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The icon is small, the target is not. Neighbours keep their distance from the icon itself.
        .padding(.horizontal, -Spacing.snug).padding(.vertical, -Spacing.snug)
        .impPopover(isPresented: $shown) {
            Text(verbatim: text)
                .font(Typeface.caption)
                .foregroundStyle(Tone.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Sizing.tipWidth, alignment: .leading)
                .padding(Spacing.medium)
        }
        .accessibilityLabel(text)
        .task {
            guard opensAtOnce else { return }
            try? await Task.sleep(for: .milliseconds(250))
            shown = true
        }
        .transition(.scale.combined(with: .opacity))
    }
}
