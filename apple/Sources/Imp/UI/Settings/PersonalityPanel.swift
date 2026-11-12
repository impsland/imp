import ImpDesign
import ImpKit
import SwiftUI

/// Who the Imp is: its name, its persona and how its voice shows. The name is part of the personality,
/// not of the look.
struct PersonalityPanel: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var name = ""
    @State private var loaded = false
    @State private var showsInstructions = false
    @Environment(\.impTint) private var tint

    private var nameIsEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    private static var wellHeight: CGFloat { Sizing.control * 4 }

    var body: some View {
        PanelSection("personality.name", icon: "signature", info: "personality.help.name") {
            TextField("personality.name", text: $name).impField()
                .accessibilityLabel(Text("personality.name"))
                .onChange(of: name) { _, new in
                    // An empty name is not saved: the Imp keeps the one it had.
                    if !new.trimmingCharacters(in: .whitespaces).isEmpty { imp.name = new }
                }
            if nameIsEmpty {
                StatusText(text: "personality.name_empty", symbol: "exclamationmark.circle.fill", color: Tone.danger)
            }
        }
        .settingAnchor(.personalityName)
        .onAppear { if !loaded { name = imp.name; loaded = true } }

        PanelSection("personality.persona", icon: "theatermasks.fill", info: "personality.help.persona") {
            EditorWell(text: $imp.personality,
                       placeholder: "A grumpy librarian who loves puns? A cheerful cheerleader?",
                       height: Self.wellHeight)
            instructions
        }
        .settingAnchor(.personalityPersona)

        PanelSection("personality.voice", icon: "waveform", info: "personality.help.voice") {
            Row("personality.voice_look", icon: "speaker.wave.2.fill", info: "personality.help.voice_look") {
                ImpSegmented("personality.voice_look", selection: $model.prefs.voiceStyle,
                             options: [VoiceStyle.both, .glow, .orb, .players],
                             title: { style in
                    switch style {
                    case .both: String(localized: "Both")
                    case .glow: String(localized: "Glow")
                    case .orb: String(localized: "Smoke")
                    case .players: String(localized: "Players")
                    }
                }, symbol: { style in
                    switch style {
                    case .both: "square.stack.fill"
                    case .glow: "sun.max.fill"
                    case .orb: "smoke.fill"
                    case .players: "play.rectangle.fill"
                    }
                })
            }
            .settingAnchor(.personalityVoiceLook)
        }
        .settingAnchor(.personalityVoice)
    }

    /// The rest of the system prompt, folded away: most people never need it, but it is all theirs to change.
    private var instructions: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Row("Reply rules", icon: "list.bullet.rectangle", info: "personality.help.rules") {
                HStack(spacing: Spacing.small) {
                    if showsInstructions {
                        Button { imp.instructions = nil } label: { FitLabel("Restore Default", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(.imp(.quiet, small: true))
                            .disabled(imp.instructions == nil)
                    }
                    Toggle("Reply rules", isOn: $showsInstructions)
                        .labelsHidden().toggleStyle(.impSwitchBare)
                }
            }
            .settingAnchor(.personalityRules)
            if showsInstructions {
                EditorWell(text: Binding(get: { imp.effectiveInstructions },
                                         set: { imp.instructions = $0 == Briefing.display ? nil : $0 }),
                           placeholder: "Empty. Only the personality is sent.",
                           height: Self.wellHeight)
            }
        }
        .impAnimation(ImpDesign.Motion.expand, value: showsInstructions)
    }
}
