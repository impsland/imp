import ImpKit
import SwiftUI
import ImpDesign

/// An Imp's right-click menu header: a little Imp, its status, and the two things you do most. It has the same
/// inset, width and buttons as the menu bar panel, so both menus line up.
struct MenuHeader: View {
    /// Draws the Imp larger, with the horns scaled down so they keep their previous on-screen size.
    static func portrait(ready: Bool, hue: Double) -> Face {
        var f = Face.settled(ready ? .idle : .sad, lookX: 0.35, lookY: 0.25)
        f.hornSize *= 46.0 / 54.0
        f.hue = hue
        return f
    }

    let ready: Bool
    let name: String
    let hue: Double
    let status: String
    let talk: () -> Void
    let type: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.cozy) {
                ImpPortrait(face: Self.portrait(ready: ready, hue: hue), shadow: false)
                    .frame(width: BubbleMetrics.portrait, height: BubbleMetrics.portrait)
                    .background(Circle().fill(Color.imp(hue).opacity(Opacity.tintFill)).padding(Spacing.hairline))
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(name).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    HStack(spacing: Spacing.snug) {
                        Circle().fill(ready ? Tone.good : Tone.accent).frame(width: BubbleMetrics.pip, height: BubbleMetrics.pip)
                        Text(status).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            QuickBar(buttons: [
                QuickBar.Item(icon: "mic.fill", title: "menu.imp.talk", help: words("menu.imp.talk_help", name), action: talk),
                QuickBar.Item(icon: "keyboard.fill", title: "menu.imp.type", help: words("menu.imp.type_help", name), action: type),
            ])
        }
        .padding(Spacing.medium)
        .frame(minWidth: Sizing.menuWidth, maxWidth: .infinity, alignment: .leading)
    }
}

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
        HStack(spacing: Spacing.snug) {
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
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                VStack(spacing: Spacing.tight) {
                    Image(systemName: icon).font(.icon(.large, weight: .semibold))
                    Text(title).font(Typeface.small.weight(.medium)).lineLimit(1).fixedSize()
                }
                .padding(Spacing.snug)
                Image(systemName: icon).font(.icon(.large, weight: .semibold))
                    .padding(Spacing.snug)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: Sizing.hit)
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
