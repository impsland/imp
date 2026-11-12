import SwiftUI

// Icon-only buttons and menus: a bare glyph with no background of its own until it is pointed at
// or pressed, when it grows a soft circle. The glyph is `Tone.muted` unless a colour is given, and a
// given colour (an Imp's tint, say) is made legible on the surface first (`LegibleTint`).

/// A bare glyph that grows a soft circle on hover or press. Shared by icon buttons and icon menus.
public struct HoverGlyph: View {
    let systemName: String
    var tint: Color
    var pressed: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    public init(systemName: String, tint: Color = Tone.muted, pressed: Bool = false) {
        self.systemName = systemName
        self.tint = tint
        self.pressed = pressed
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.icon(.large, weight: .medium))
            .foregroundStyle(LegibleTint(tint))
            .frame(width: Sizing.glyph, height: Sizing.glyph)
            .background(Circle().fill(tint.opacity(pressed ? Opacity.tintFillStrong : (hover ? Opacity.tintFill : 0))))
            .focusRing(Circle(), shown: focused)
            .frame(minWidth: Sizing.hit, minHeight: Sizing.hit)
            .contentShape(Circle())
            .opacity(enabled ? 1 : Opacity.disabled)
            .impAnimation(Motion.quick, value: hover)
            .onHover { hover = $0 && enabled }
    }
}

/// Icon-only button with a hover circle. Always give it a `help`.
public struct HoverIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color
    let action: () -> Void

    public init(systemName: String, help: LocalizedStringKey, tint: Color = Tone.muted, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(GlyphStyle(systemName: systemName, tint: tint))
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct GlyphStyle: ButtonStyle {
    let systemName: String
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HoverGlyph(systemName: systemName, tint: tint, pressed: configuration.isPressed)
    }
}

/// Icon-only menu with the same hover circle.
public struct HoverIconMenu<Content: View>: View {
    let systemName: String
    let help: LocalizedStringKey
    let content: Content

    public init(systemName: String, help: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.systemName = systemName
        self.help = help
        self.content = content()
    }

    public var body: some View {
        Menu { content } label: { HoverGlyph(systemName: systemName) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(help)
            .accessibilityLabel(help)
    }
}
