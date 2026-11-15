import ImpDesign
import ImpKit
import SwiftUI

/// The Look panel: the Imp as big as it is in the room, then its colour, its size and its character. Every change
/// shows at once, without animation, and is kept as it is made.
struct PocketLookPanel: View {
    @Bindable var draft: PocketDraft

    static let sizes: ClosedRange<Double> = 0.75...1.7

    private var percent: String { "\(Int((draft.scale * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            stage
            PocketCard(title: "look.colour") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Sizing.hit), spacing: 0)], spacing: 0) {
                    ForEach(Array(PocketDraft.hues.enumerated()), id: \.offset) { index, hue in
                        swatch(hue, index: index)
                    }
                }
                .selectionHaptic(draft.hue)
            }
            PocketCard(title: "look.size", value: percent) {
                Slider(value: $draft.scale, in: Self.sizes, step: 0.05).impSlider()
                    .accessibilityLabel(Text("look.size"))
                    .accessibilityValue(percent)
                    .accessibilityIdentifier("look.size")
                    .frame(minHeight: Sizing.hit)
                    // A tick at each step, so the size is felt as well as seen.
                    .selectionHaptic(draft.scale)
            }
            PocketCard(title: "look.character", tip: String(localized: "look.help.character")) {
                // As on the Mac: Reset is an action on the character, so an icon in its card's header.
                HoverIconButton(systemName: "arrow.counterclockwise", help: "look.reset") { draft.resetCharacter() }
                    .disabled(draft.isPlainCharacter)
            } content: {
                EmojiRow("look.character", items: ImpTraits.presets.map { .init(id: $0.id, emoji: $0.emoji, name: $0.name) },
                         picked: draft.traits.preset?.id) { id in
                    if let preset = ImpTraits.presets.first(where: { $0.id == id }) { draft.traits = preset.traits }
                }
                .selectionHaptic(draft.traits.preset?.id)
                let t = $draft.traits
                TraitSlider(label: "look.lids", value: t.lids, range: 0...0.6, shown: "\(Int((draft.traits.lids / 0.6 * 100).rounded()))%")
                TraitSlider(label: "look.brows", value: t.slant, range: -1...1, shown: String(format: "%+.1f", draft.traits.slant))
                TraitSlider(label: "look.eyes", value: t.eyes, range: -0.4...0.4, shown: String(format: "%+.0f%%", draft.traits.eyes * 100))
                TraitSlider(label: "look.squint", value: t.squint, range: -1...1, shown: String(format: "%+.1f", draft.traits.squint))
                TraitSlider(label: "look.horns", value: t.horns, range: -30...30, shown: "\(Int(draft.traits.horns.rounded()))°")
                TraitSlider(label: "look.cheeks", value: t.blush, range: 0...1, shown: "\(Int((draft.traits.blush * 100).rounded()))%")
                TraitSlider(label: "look.head", value: t.tilt, range: -12...12, shown: "\(Int(draft.traits.tilt.rounded()))°")
                TraitSlider(label: "look.pace", value: t.tempo, range: 0.6...1.6, shown: String(format: "%.1f×", draft.traits.tempo))
            }
        }
    }

    /// The Imp at its size in the room (the stage's own measure), on a floor as tall as the biggest one. It follows the
    /// slider exactly, with no zoom of its own, and takes a new colour or character at once.
    private var stage: some View {
        let side = StageEngine.baseSize * draft.scale
        // Live, not a still: a new colour or character springs in as it does in the room.
        return LiveImp(imp: LinkImp(id: draft.id, name: draft.name, hue: draft.hue, scale: 1, traits: draft.traits))
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, minHeight: StageEngine.baseSize * Self.sizes.upperBound, alignment: .bottom)
            .transaction { $0.animation = nil }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: draft.name))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("look.preview")
    }

    private func swatch(_ hue: Double, index: Int) -> some View {
        let picked = abs(draft.hue - hue) < 0.02
        return Button { draft.hue = hue } label: {
            Circle().fill(Color.imp(hue))
                .frame(width: Sizing.hit - Spacing.cozy, height: Sizing.hit - Spacing.cozy)
                .background {
                    // The pick is a ring of focus colour behind the swatch, a fill and not an outline.
                    if picked { Circle().fill(Tone.focus).padding(-Spacing.hairline * 2) }
                }
                .frame(width: Sizing.hit, height: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words("look.swatch", index + 1, PocketDraft.hues.count))
        .accessibilityIdentifier("look.swatch.\(index)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The Personality panel: who the Imp is. Its name, and how it talks.
struct PocketPersonalityPanel: View {
    @Bindable var draft: PocketDraft
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            PocketCard(title: "personality.name") {
                TextField("personality.name", text: $draft.name)
                    .impField()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityIdentifier("personality.name")
                if let problem = draft.nameProblem { IssueBadge(text: problem) }
                else if draft.name.trimmed.isEmpty { IssueBadge(text: String(localized: "personality.name_empty")) }
            }
            PocketCard(title: "personality.persona") {
                TextArea("personality.persona", text: $draft.personality, placeholder: "phone.persona.placeholder", minLines: 3, maxLines: 8)
                    .focused($focused)
                    .submitLabel(.done)
                    // One paragraph: Return puts the keyboard away instead of starting a new line.
                    .onChange(of: draft.personality) { _, text in
                        guard text.contains("\n") else { return }
                        draft.personality = text.replacingOccurrences(of: "\n", with: "")
                        focused = false
                    }
            }
        }
    }
}
