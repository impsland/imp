import SwiftUI

/// What's wrong (or worth knowing) about something, kept out of the way: a small icon next to it,
/// whose words show in a tooltip when you tap it. The app never spells problems out inline.
struct IssueBadge: View {
    enum Kind {
        /// Something to fix before it works.
        case problem
        /// A tip: nothing's wrong.
        case info
    }

    var text: String
    var kind: Kind = .problem
    /// Opens the tooltip as soon as it appears (for a problem you just caused, like a bad paste).
    var opensAtOnce = false
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: kind == .problem ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind == .problem ? Dungeon.flame : Dungeon.muted)
                .symbolEffect(.bounce, value: text)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .popover(isPresented: $showing, attachmentAnchor: .point(.center), arrowEdge: .bottom) {
            Text(text)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.cream)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Dungeon.deep)
        }
        .task(id: text) {
            guard opensAtOnce else { return }
            try? await Task.sleep(for: .milliseconds(250))
            showing = true
        }
        .transition(.scale.combined(with: .opacity))
    }
}
