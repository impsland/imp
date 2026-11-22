import ImpCore
import ImpDesign
import ImpKit
import SwiftUI

/// The custom commands that match what is typed after a `/`, above the keyboard: a tap puts the command in the box.
struct CommandList: View {
    let commands: [CommandEntry]
    let pick: (CommandEntry) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.name) { command in
                    Button { pick(command) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(command.usage)
                                .font(Typeface.label)
                                .foregroundStyle(Tone.text)
                            if !command.about.isEmpty {
                                Text(command.about)
                                    .font(Typeface.small)
                                    .foregroundStyle(Tone.muted)
                            }
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
                        .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: Sizing.hit * 3)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }
}
