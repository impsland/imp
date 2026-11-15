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
    /// The reply rules are open in their sheet.
    @State private var editingRules = false

    private var nameIsEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    private static var wellHeight: CGFloat { Sizing.control * 4 }

    var body: some View {
        PanelSection("personality.name", icon: "signature", info: "personality.help.name") {
            // An empty field says what it needs in its own prompt, with a red ring and mark. No line under
            // the field is kept free for a message that rarely appears.
            TextField("personality.name", text: $name, prompt: nameIsEmpty ? Text("personality.name_empty") : nil)
                .impField(problem: nameIsEmpty ? String(localized: "personality.name_empty") : nil)
                .accessibilityLabel(Text("personality.name"))
                .onChange(of: name) { _, new in
                    // An empty name is not saved: the Imp keeps the one it had.
                    if !new.trimmingCharacters(in: .whitespaces).isEmpty { imp.name = new }
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

    /// The rest of the system prompt: most people never need it, but it is all theirs to change. One row
    /// says whether it is the built-in one and opens it in a sheet. The prompt is never edited inline,
    /// since building a large editor in the panel stalled the switch and moved the page.
    private var instructions: some View {
        Row("Reply rules", icon: "list.bullet.rectangle", info: "personality.help.rules") {
            HStack(spacing: Spacing.small) {
                Text(imp.instructions == nil ? "personality.rules.builtin" : "personality.rules.own")
                    .font(Typeface.small).foregroundStyle(Tone.muted)
                Button { editingRules = true } label: { FitLabel("personality.rules.edit", systemImage: "pencil") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }
        .settingAnchor(.personalityRules)
        .sheet(isPresented: $editingRules) { ReplyRulesSheet(imp: $imp) }
    }

    /// The height of the reply rules editor inside its sheet.
    fileprivate static var editorHeight: CGFloat { wellHeight * 2.5 }
}

/// The reply rules in a sheet of their own: the whole built-in prompt to change, and the way back to it.
/// Changes apply as they are typed, like the rest of the panel.
private struct ReplyRulesSheet: View {
    @Binding var imp: ImpProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(icon: "list.bullet.rectangle", title: "Reply rules", info: "personality.help.rules",
                      width: Sizing.sheetWidth + Spacing.vast) {
            // Text equal to the built-in prompt is stored as nil, so the built-in one stays in use.
            EditorWell(text: Binding(get: { imp.effectiveInstructions },
                                     set: { imp.instructions = $0 == Briefing.display ? nil : $0 }),
                       placeholder: "Empty. Only the personality is sent.",
                       height: PersonalityPanel.editorHeight)
        } footer: {
            Button { imp.instructions = nil } label: { FitLabel("Restore Default", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.quiet)
                .disabled(imp.instructions == nil)
            Button("common.done") { dismiss() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
