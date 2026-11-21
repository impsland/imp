import ImpKit
import SwiftUI
import ImpDesign

/// A row of equal pebble buttons, icon over label, for the top of a menu. A button whose label does not fit its
/// width shows the icon alone. The label stays as its spoken name.
struct QuickBar: View {
    struct Item {
        var icon: String
        var title: LocalizedStringKey
        var help: String
        var enabled = true
        var action: () -> Void
    }

    let buttons: [Item]

    var body: some View {
        HStack(spacing: MenuMetrics.inset) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                QuickButton(icon: b.icon, title: b.title, action: b.action)
                    .disabled(!b.enabled)
                    .help(b.help)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One pebble button: the icon over its label, both inset from the pebble's edge on every side.
struct QuickButton: View {
    let icon: String
    let title: Text
    let action: () -> Void
    /// Half as tall, with the icon beside the one-line word (see `MenuMetrics.compactHeight`).
    var compact = false

    init(icon: String, title: LocalizedStringKey, action: @escaping () -> Void) {
        self.icon = icon; self.title = Text(title); self.action = action
    }

    /// For words that are already localized (a name, a count).
    init(icon: String, verbatim title: String, compact: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.title = Text(verbatim: title); self.compact = compact; self.action = action
    }

    var body: some View {
        Button(action: action) {
            if compact {
                HStack(spacing: MenuMetrics.inset / 2) {
                    MenuGlyph(name: icon, size: .small, box: MenuMetrics.compactGlyph)
                    title.font(Typeface.small.weight(.medium)).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, MenuMetrics.inset)
                .frame(maxWidth: .infinity, minHeight: MenuMetrics.compactHeight)
            } else {
                // One line if the words fit, else two, and the icon alone only when not even that fits.
                ViewThatFits(in: .horizontal) {
                    VStack(spacing: 0) {
                        MenuGlyph(name: icon)
                        title.font(Typeface.small.weight(.medium)).lineLimit(1).fixedSize()
                    }
                    .padding(MenuMetrics.inset)
                    VStack(spacing: 0) {
                        MenuGlyph(name: icon)
                        title.font(Typeface.small.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(MenuMetrics.inset)
                    MenuGlyph(name: icon)
                        .padding(MenuMetrics.inset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: Sizing.hit)
            }
        }
        .buttonStyle(PebbleButtonStyle())
        .accessibilityLabel(title)
    }
}

/// A soft pebble that brightens on hover and dips when pressed. No outline.
struct PebbleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PebbleFace(configuration: configuration)
    }
}

private struct PebbleFace: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let on = hover && enabled
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        configuration.label
            .foregroundStyle(Tone.text)
            .background(configuration.isPressed ? Tone.well : on ? Tone.cardHover : Tone.card, in: shape)
            .contentShape(shape)
            .opacity(enabled ? 1 : Opacity.disabled)
            .impAnimation(ImpDesign.Motion.press, value: configuration.isPressed)
            .impAnimation(ImpDesign.Motion.quick, value: on)
            .onHover { hover = $0 }
    }
}
