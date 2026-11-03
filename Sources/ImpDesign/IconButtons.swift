import SwiftUI

// Icon-only buttons and menus: a bare glyph that grows a soft circle on hover.

/// A bare glyph that grows a soft circle on hover. Shared by icon buttons and icon menus.
public struct HoverGlyph: View {
    let systemName: String
    var tint: Color
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.impTint) private var ring

    public init(systemName: String, tint: Color = .secondary) {
        self.systemName = systemName
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hover ? tint : tint.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(hover ? 0.14 : 0)))
            .overlay(Circle().strokeBorder(ring, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
            .contentShape(Circle())
            .opacity(enabled ? 1 : 0.4)
            .animation(Timing.quick, value: hover)
            .onHover { hover = $0 && enabled }
    }
}

/// Icon-only button with a hover circle. Always give it a `help`.
public struct HoverIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color
    let action: () -> Void

    public init(systemName: String, help: LocalizedStringKey, tint: Color = .secondary, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) { HoverGlyph(systemName: systemName, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
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
