import ImpDesign
import SwiftUI

extension ImpSetting {
    /// The marker's name and the panel's title.
    var title: LocalizedStringResource {
        switch self {
        case .brain: "imp_settings.marker.brain"
        case .look: "imp_settings.marker.look"
        case .personality: "imp_settings.marker.personality"
        case .tools: "imp_settings.marker.tools"
        case .triggers: "imp_settings.marker.triggers"
        case .animations: "imp_settings.marker.animations"
        case .computer: "imp_settings.marker.computer"
        }
    }
}

/// The round glyph of a setting. The Brain's is a lantern that is lit when the Brain works and unlit,
/// calm and not a warning, when the Imp sleeps.
private struct PhoneGlyph: View {
    let setting: ImpSetting
    let lit: Bool
    var picked = false

    var body: some View {
        IconTile(systemName: setting == .brain && !lit ? "lightbulb" : setting.symbol, filled: picked)
            .opacity(lit ? 1 : Opacity.dimmed)
    }
}

/// A setting as a row of the Imp's settings: its glyph, its name, a short state and the way in.
struct PhoneListRow: View {
    let setting: ImpSetting
    let value: String?
    let lit: Bool
    let asleepNote: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.medium) {
                PhoneGlyph(setting: setting, lit: lit)
                Text(setting.title).font(Typeface.body).foregroundStyle(Tone.text).layoutPriority(1)
                Spacer(minLength: Spacing.small)
                if let value {
                    Text(verbatim: value).font(Typeface.caption).foregroundStyle(Tone.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.right").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(setting.title))
        .accessibilityValue(setting == .brain && !lit ? asleepNote : (value ?? ""))
    }
}

/// A soft card of a panel: one header (title, then on the trailing side an optional value or action and at
/// most one help tip) and rows inside. An action on the whole card (Reset, Add, Change) sits in the header,
/// never alone under the rows.
struct PocketCard<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    var tip: String?
    var value: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            SectionHeader(info: nil, verbatimInfo: tip, minHeight: nil, accessory: {
                if let value { Text(verbatim: value).font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.muted) }
                accessory
            }, leading: {
                Text(title).font(Typeface.label).foregroundStyle(Tone.text).accessibilityAddTraits(.isHeader)
            })
            content
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.card))
    }
}

extension PocketCard where Accessory == EmptyView {
    init(title: LocalizedStringKey, tip: String? = nil, value: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, tip: tip, value: value, accessory: { EmptyView() }, content: content)
    }
}

/// A slider row: its title and value over the slider. The title is the row's only label.
struct TraitSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let shown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label).font(Typeface.small).foregroundStyle(Tone.muted)
                Spacer(minLength: Spacing.small)
                Text(verbatim: shown).font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.muted)
            }
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .impSlider()
            .accessibilityLabel(Text(label))
            .accessibilityValue(shown)
        }
        .frame(minHeight: Sizing.hit)
    }
}

/// Lays chips out in rows, wrapping to the next line when they don't fit.
struct Wrap: Layout {
    var spacing: CGFloat = Spacing.small

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews)
        for (view, origin) in zip(subviews, laid.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + row), origins)
    }
}

#Preview("Settings rows") {
    VStack(spacing: 0) {
        ForEach([ImpSetting.brain, .personality, .look, .tools]) { setting in
            PhoneListRow(setting: setting, value: setting == .brain ? "Asleep" : nil, lit: setting != .brain, asleepNote: "Dot is asleep. Give it a Brain.") {}
        }
    }
    .padding().background(Tone.surface).impControls(tint: Tone.accent)
}
