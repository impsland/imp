import ImpDesign
import ImpKit
import SwiftUI

/// Colour, size and character in one panel, all sliders. The Imp in the middle is the preview, so
/// nothing is drawn twice. Only the whole Imp is shared in The Den: the look travels with it.
struct LookPanel: View {
    @Binding var imp: ImpProfile
    @Environment(\.impTint) private var tint

    private var isDefault: Bool {
        let base = ImpProfile.imp
        return abs(imp.hue - base.hue) < 0.005 && abs(imp.scale - 1) < 0.01 && imp.traits.isPlain
    }

    var body: some View {
        PanelSection("look.body", icon: "paintpalette.fill", info: "look.help.body") {
            Row("look.colour", icon: "paintpalette", info: "look.help.colour") { colour }
            .settingAnchor(.lookColour)
            Row("look.size", icon: "arrow.up.left.and.arrow.down.right", info: "look.help.size") {
                RowSlider(value: $imp.scale, range: 0.75...1.7, step: 0.05, label: "look.size",
                          shown: "\(Int((imp.scale * 100).rounded()))%", resets: 1)
            }
            .settingAnchor(.lookSize)
        }
        PanelSection("look.character", icon: "theatermasks", info: "look.help.character", accessory: { resetButton }) {
            character
        }
        .settingAnchor(.lookCharacter)
    }

    private var resetButton: some View {
        HoverIconButton(systemName: "arrow.counterclockwise", help: "look.reset", action: reset)
            .disabled(isDefault)
    }

    // MARK: Colour

    /// The colour wheel as a strip under a slider (a picture of the choices, not decoration), and the
    /// heart when the Imp has a favourite colour.
    private var colour: some View {
        HStack(spacing: Spacing.cozy) {
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: (0...12).map { Color.imp(Double($0) / 12) }, startPoint: .leading, endPoint: .trailing))
                    .frame(height: Spacing.cozy)
                    .accessibilityHidden(true)
                Slider(value: $imp.hue, in: 0...1).impSlider()
                    .accessibilityLabel(Text("look.colour"))
                    .accessibilityValue("\(Int((imp.hue * 100).rounded()))%")
            }
            .frame(minWidth: Sizing.hit * 4, maxWidth: Sizing.hit * 7)
            if imp.knowsFavorite {
                HoverIconButton(systemName: "heart.fill", help: "look.favourite", tint: Color.imp(imp.favoriteHue)) {
                    imp.hue = imp.favoriteHue
                }
                .accessibilityValue(Text(verbatim: "\(Int((imp.favoriteHue * 100).rounded()))%"))
            }
        }
    }

    // MARK: Character

    private var character: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            EmojiRow("look.character", items: ImpTraits.presets.map { .init(id: $0.id, emoji: $0.emoji, name: $0.name) },
                     picked: imp.traits.preset?.id) { id in
                if let preset = ImpTraits.presets.first(where: { $0.id == id }) { imp.traits = preset.traits }
            }
            trait("look.lids", "eye.slash", "look.help.lids", $imp.traits.lids, 0...0.6, format: Self.percent(0.6))
            trait("look.brows", "eyebrow", "look.help.brows", $imp.traits.slant, -1...1) { String(format: "%+.1f", $0) }
            trait("look.eyes", "eye", "look.help.eyes", $imp.traits.eyes, -0.4...0.4) { String(format: "%+.0f%%", $0 * 100) }
            trait("look.squint", "eye.trianglebadge.exclamationmark", "look.help.squint", $imp.traits.squint, -1...1) { String(format: "%+.1f", $0) }
            trait("look.horns", "arrowtriangle.up.fill", "look.help.horns", $imp.traits.horns, -30...30) { "\(Int($0.rounded()))°" }
            trait("look.cheeks", "face.smiling", "look.help.cheeks", $imp.traits.blush, 0...1, format: Self.percent(1))
            trait("look.head", "rotate.right", "look.help.head", $imp.traits.tilt, -12...12) { "\(Int($0.rounded()))°" }
            trait("look.pace", "gauge.with.dots.needle.67percent", "look.help.pace", $imp.traits.tempo, 0.6...1.6, resets: 1) { String(format: "%.1f×", $0) }
        }
    }

    /// One trait: its picture, its name and help, and a slider with its value. Double-click puts it back.
    private func trait(_ label: LocalizedStringKey, _ icon: String, _ info: LocalizedStringKey, _ value: Binding<Double>,
                       _ range: ClosedRange<Double>, resets: Double? = nil, format: @escaping (Double) -> String) -> some View {
        Row(label, icon: icon, info: info) {
            RowSlider(value: value, range: range, label: label, shown: format(value.wrappedValue),
                      resets: resets ?? min(max(0, range.lowerBound), range.upperBound))
        }
    }

    private static func percent(_ max: Double) -> (Double) -> String { { "\(Int(($0 / max * 100).rounded()))%" } }

    private func reset() {
        let base = ImpProfile.imp
        imp.hue = base.hue
        imp.scale = 1
        imp.traits = .plain
    }
}
