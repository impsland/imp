import ImpDesign
import ImpKit
import SwiftUI

/// The Look panel: colour swatches, size and character. Every change applies to the Imp above at once.
struct PocketLookPanel: View {
    @Bindable var draft: PocketDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            PocketCard(title: "look.colour") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Sizing.hit), spacing: 0)], spacing: 0) {
                    ForEach(Array(PocketDraft.hues.enumerated()), id: \.offset) { index, hue in
                        swatch(hue, index: index)
                    }
                }
            }
            PocketCard(title: "look.size", value: "\(Int((draft.scale * 100).rounded()))%") {
                Slider(value: $draft.scale, in: 0.75...1.7, step: 0.05).impSlider()
                    .accessibilityLabel(Text("look.size"))
                    .accessibilityValue("\(Int((draft.scale * 100).rounded()))%")
                    .frame(minHeight: Sizing.hit)
            }
            PocketCard(title: "look.character", tip: String(localized: "look.help.character")) {
                Wrap(spacing: Spacing.small) {
                    ForEach(ImpTraits.presets) { p in
                        ChoiceChip(verbatim: "\(p.emoji) \(p.name)", picked: draft.traits.preset?.id == p.id) { draft.traits = p.traits }
                    }
                }
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
            Button("look.reset") { draft.resetLook() }
                .buttonStyle(.quiet)
                .disabled(draft.isPlainLook)
        }
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
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The Personality panel: how the Imp talks. Its name is under it on the hub.
struct PocketPersonalityPanel: View {
    @Bindable var draft: PocketDraft
    @FocusState private var focused: Bool

    var body: some View {
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

/// The Brain panel: the guided setup in place for an Imp that sleeps, the current service and model with
/// "Change" for one that thinks. The flow owns the editing, the draft only reads its result.
struct PocketBrainPanel: View {
    let draft: PocketDraft
    let flow: FirstRunModel?
    let change: () -> Void

    var body: some View {
        if let flow {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                FirstRunPhoneSteps(flow: flow).frame(maxWidth: .infinity)
                FirstRunPhoneFlow(flow: flow)
            }
        } else {
            PocketCard(title: "brain.title", tip: words("brain.hint", draft.name.trimmed.isEmpty ? String(localized: "imp_settings.this_imp") : draft.name.trimmed)) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(verbatim: draft.serviceName).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    Text(verbatim: draft.brain.model).font(Typeface.mono).foregroundStyle(Tone.muted).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                Button("phone.brain.change", action: change).buttonStyle(.secondary)
            }
        }
    }
}
