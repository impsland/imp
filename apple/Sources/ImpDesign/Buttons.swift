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
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    func body(content: Content) -> some View {
        OneLine { content }
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? Spacing.cozy : Spacing.roomy)
            .padding(.vertical, small ? Spacing.tight : Spacing.snug)
            .frame(minHeight: small ? Sizing.control - Spacing.tight : Sizing.hit)
            .background(Capsule().fill(fill))
            .focusRing(Capsule(), shown: focused)
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled ? 1 : Opacity.disabled)
            .impAnimation(Motion.press, value: pressed)
            .impAnimation(Motion.hover, value: hover)
            .onHover { hover = $0 && enabled }
    }

    private var font: Font { small ? Typeface.label : Typeface.body.weight(.semibold) }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(OnTint(tint))
        case .secondary, .quiet: AnyShapeStyle(Tone.text)
        case .destructive: AnyShapeStyle(Tone.danger)
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(TintFill(tint).opacity(hover ? Opacity.hoverFill : 1))
        case .secondary: return AnyShapeStyle(tint.opacity(hover ? Opacity.tintFillStrong : Opacity.tintFill))
        case .quiet: return AnyShapeStyle(hover ? Tone.cardHover : Tone.card)
        case .destructive: return AnyShapeStyle(hover ? Tone.errorEdge : Tone.errorBackground)
        }
    }
}

extension View {
    /// Dresses a label (e.g. a `Menu` label) as an Imp pill button.
    public func impPill(_ kind: ImpButtonStyle.Kind, small: Bool = false, pressed: Bool = false) -> some View {
        modifier(ImpPill(kind: kind, small: small, pressed: pressed))
    }
}

/// Keeps a label on one line without squeezing it. The label gets the width on offer when it can stay
/// on one line there (a `FitLabel` switching to its icon does). If that width would wrap its words,
/// it keeps its natural width instead, so a title is never wrapped, cut short or shrunk.
struct OneLine: Layout {
    private func fits(_ child: LayoutSubview, _ proposal: ProposedViewSize) -> Bool {
        child.sizeThatFits(proposal).height <= child.sizeThatFits(.unspecified).height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return fits(child, proposal) ? child.sizeThatFits(proposal) : child.sizeThatFits(.unspecified)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let offer = fits(child, proposal) ? proposal : .unspecified
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: offer)
    }
}

/// Icon and title close together, icon a touch smaller.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.snug) {
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

/// The phone's big button: a full-width capsule, filled with the tint or a soft pebble.
public struct WideButtonStyle: ButtonStyle {
    public var filled = true

    public init(filled: Bool = true) { self.filled = filled }

    public func makeBody(configuration: Configuration) -> some View {
        Wide(configuration: configuration, filled: filled)
    }

    private struct Wide: View {
        let configuration: Configuration
        let filled: Bool
        @Environment(\.impTint) private var tint
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(Typeface.cardTitle)
                .lineLimit(1)
                .foregroundStyle(filled ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                .padding(.horizontal, Spacing.wide).padding(.vertical, Spacing.medium)
                .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                .background(Capsule().fill(filled ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
                .focusRing(Capsule(), shown: focused)
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : Opacity.disabled)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        }
    }
}
