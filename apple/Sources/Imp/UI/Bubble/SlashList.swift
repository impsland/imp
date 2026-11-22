import ImpCore
import ImpDesign
import ImpKit
import SwiftUI

/// The custom commands that match what is typed after a `/`: name, what it takes and what it does, one
/// per row. ↑ ↓ move, ⇥ completes, ↩ completes (and sends a command that takes no arguments), ⎋ closes.
struct SlashList: View {
    @Environment(\.impTint) private var tint
    let commands: [CommandEntry]
    let picked: Int
    let pick: (CommandEntry) -> Void

    /// How many rows show at once.
    static let rows = 6

    /// The rows in sight: the picked one is always among them.
    private var visible: ArraySlice<CommandEntry> {
        let start = max(0, picked - Self.rows + 1)
        return commands[start..<min(commands.count, start + Self.rows)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.name) { _, command in
                let selected = command.name == commands[picked].name
                Button { pick(command) } label: {
                    HStack(spacing: Spacing.snug) {
                        Text(command.usage)
                            .font(Typeface.label)
                            .foregroundStyle(Tone.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(command.about)
                            .font(Typeface.small)
                            .foregroundStyle(Tone.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(selected ? tint.opacity(Opacity.tintFill) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.tight)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }
}
