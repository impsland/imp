import ImpKit
import SwiftUI

/// Name, colour, size and who the Imp is.
struct LooksTab: View {
    @Binding var imp: ImpProfile
    @Environment(\.impTint) private var tint
    @State private var showsInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Appearance", icon: "paintpalette.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    FieldRow("Name") {
                        TextField("What do you call it?", text: $imp.name).impField()
                    }
                    FieldRow("Colour", info: favoriteInfo) {
                        EvenGrid(minWidth: 30, spacing: 4) {
                            ForEach(ImpProfile.colors, id: \.hue) { c in
                                let loved = imp.knowsFavorite && abs(imp.favoriteHue - c.hue) < 0.005
                                Button { withAnimation(.snappy) { imp.hue = c.hue } } label: {
                                    Swatch(fill: AnyShapeStyle(Color.imp(c.hue)), picked: abs(imp.hue - c.hue) < 0.005, loved: loved)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .help(loved ? Text("\(c.name), \(displayName)'s favourite") : Text(verbatim: c.name))
                                .accessibilityLabel(c.name)
                            }
                        }
                    }
                    FieldRow("Shade") {
                        HueSlider(hue: $imp.hue).help("Any shade in between")
                    }
                    FieldRow("Size") {
                        EvenGrid(minWidth: 70, spacing: 6) {
                            ForEach(Self.sizes, id: \.scale) { s in sizeTile(s) }
                        }
                    }
                }
            }

            Card("Personality", icon: "theatermasks.fill",
                 info: "How \(displayName) talks. Start from a template, then edit the words.") {
                EvenGrid(minWidth: 112, spacing: 6) {
                    ForEach(Persona.templates) { p in
                        ChoiceChip(verbatim: "\(p.emoji) \(p.name)", picked: imp.personality == p.prompt(for: displayName)) {
                            imp.personality = p.prompt(for: displayName)
                        }
                        .help(p.summary)
                    }
                }
                EditorWell(text: $imp.personality,
                           placeholder: "A grumpy librarian who loves puns? A cheerful cheerleader?",
                           height: 120)
                CardDivider()
                instructions
            }
        }
    }

    /// The rest of the system prompt, folded away: most people never need it, but it's all
    /// theirs to change.
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { withAnimation(.snappy(duration: 0.22)) { showsInstructions.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showsInstructions ? 90 : 0))
                        Text("Reply rules").font(.system(size: 13, weight: .semibold))
                        if imp.instructions != nil {
                            Text("Edited").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6).frame(height: 17)
                                .background(Capsule().fill(tint.opacity(0.18)))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(showsInstructions ? "Shown" : "Hidden")
                InfoTip("Sent after the personality in every chat. They say where \(displayName) works and how replies are shown. {workspace} stands for its folder. Clear them to send the personality alone.")
                Spacer(minLength: 8)
                if showsInstructions {
                    Button("Restore Default") { withAnimation(.snappy(duration: 0.2)) { imp.instructions = nil } }
                        .buttonStyle(.imp(.quiet, small: true))
                        .disabled(imp.instructions == nil)
                        .help("Back to the built-in rules")
                        .transition(.opacity)
                }
            }
            .frame(height: 24)                           // the same with or without Restore Default
            if showsInstructions {
                EditorWell(text: Binding(get: { imp.effectiveInstructions },
                                         set: { imp.instructions = $0 == Briefing.display ? nil : $0 }),
                           placeholder: "Empty. Only the personality is sent.",
                           height: 130)
                    .transition(.opacity)
            }
        }
    }

    private func sizeTile(_ s: (name: LocalizedStringKey, scale: Double)) -> some View {
        let picked = abs(imp.scale - s.scale) < 0.01
        return Button { withAnimation(.snappy) { imp.scale = s.scale } } label: {
            HStack(spacing: 6) {
                ImpPortrait(face: impFace(hue: imp.hue), shadow: false)
                    .frame(width: 12 * s.scale + 8, height: 12 * s.scale + 8)
                    .frame(width: 30, height: 30)
                Text(s.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: Metrics.control + 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(picked ? AnyShapeStyle(tint.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(0.05))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(picked ? tint : Dungeon.cardEdge, lineWidth: picked ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var favoriteInfo: LocalizedStringKey {
        imp.knowsFavorite ? "The heart marks \(displayName)'s favourite colour."
                          : "Every Imp has a favourite colour. Land on it and you'll know."
    }

    private var displayName: String { imp.callName }

    static let sizes: [(name: LocalizedStringKey, scale: Double)] = [("Small", 0.75), ("Medium", 1.0), ("Large", 1.35), ("Huge", 1.7)]
}
