import SwiftUI

// Imp's buttons: the app's own look on top of a plain SwiftUI `Button`, so the keyboard, VoiceOver
// and the Return and Esc shortcuts work as they always do. The style adds a pressed state, a
// hover state, a dimmed disabled state and a ring while the button has the keyboard focus.

/// Imp's buttons: one family, a few weights. Pills with soft fills instead of system bezels,
/// so Settings feels like the rest of Imp.
///  - `.primary`: the one main thing on a card (Run now, Grant, Save).
///  - `.secondary`: helpful extras (Test, Add, Import…).
///  - `.quiet`: low-key options (Duplicate, Cancel, Edit…).
///  - `.destructive`: Remove, Delete.
public struct ImpButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, quiet, destructive }
    public var kind: Kind
    public var small = false

    public init(kind: Kind, small: Bool = false) {
        self.kind = kind
        self.small = small
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PillLabelStyle())
            .impPill(kind, small: small, pressed: configuration.isPressed)
    }
}

/// The pill look, usable on any label (buttons, menus) so menus match buttons exactly.
private struct ImpPill: ViewModifier {
    let kind: ImpButtonStyle.Kind
    let small: Bool
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 4 : 6)
            .frame(minHeight: small ? nil : Sizing.hit)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.white.opacity(0.25) : Color.clear, lineWidth: 0.5))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
            .shadow(color: kind == .primary ? tint.opacity(hover ? 0.35 : 0.2) : .clear, radius: hover ? 6 : 3, y: 2)
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .impAnimation(.snappy(duration: 0.15), value: pressed)
            .impAnimation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 && enabled }
    }

    private var font: Font {
        #if os(iOS)
        .system(small ? .footnote : .body, design: .default, weight: .semibold)
        #else
        .system(size: small ? 11.5 : 13, weight: .semibold)
        #endif
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: scheme == .dark ? Color.white.opacity(0.94) : tint
        case .quiet: .primary
        case .destructive: scheme == .dark ? Color(red: 1, green: 0.5, blue: 0.48) : .red
        }
    }

    private var fill: AnyShapeStyle {
        let boost = hover ? 1.6 : 1
        switch kind {
        case .primary: return AnyShapeStyle(tint.gradient.opacity(hover ? 1 : 0.92))
        case .secondary: return AnyShapeStyle(tint.opacity((scheme == .dark ? 0.34 : 0.16) * boost))
        case .quiet: return AnyShapeStyle(Color.primary.opacity(0.07 * boost))
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.1 * boost))
        }
    }
}

extension View {
    /// Dresses a label (e.g. a `Menu` label) as an Imp pill button.
    public func impPill(_ kind: ImpButtonStyle.Kind, small: Bool = false, pressed: Bool = false) -> some View {
        modifier(ImpPill(kind: kind, small: small, pressed: pressed))
    }
}

/// Icon and title close together, icon a touch smaller.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == ImpButtonStyle {
    public static var primary: ImpButtonStyle { ImpButtonStyle(kind: .primary) }
    public static var secondary: ImpButtonStyle { ImpButtonStyle(kind: .secondary) }
    public static var quiet: ImpButtonStyle { ImpButtonStyle(kind: .quiet) }
    public static var destructive: ImpButtonStyle { ImpButtonStyle(kind: .destructive) }
    public static func imp(_ kind: ImpButtonStyle.Kind, small: Bool = false) -> ImpButtonStyle { ImpButtonStyle(kind: kind, small: small) }
}

/// The phone's big warm button: a full-width capsule, filled with the flame or outlined on the wall.
public struct EmberButtonStyle: ButtonStyle {
    public var filled = true

    public init(filled: Bool = true) { self.filled = filled }

    public func makeBody(configuration: Configuration) -> some View {
        Ember(configuration: configuration, filled: filled)
    }

    private struct Ember: View {
        let configuration: Configuration
        let filled: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(filled ? Dungeon.deep : Dungeon.cream)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                .background {
                    if filled {
                        Capsule().fill(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Dungeon.ember.opacity(0.4), radius: 12, y: 4)
                    } else {
                        Capsule().fill(Dungeon.card).overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                    }
                }
                .overlay(Capsule().strokeBorder(Dungeon.flame, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        }
    }
}
