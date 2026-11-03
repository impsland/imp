import SwiftUI

// The look every Imp screen shares, on the Mac and on the iPhone: one palette, one scale of
// corners, one scale of spacing, a few type styles and two animation lengths. Screens take their
// numbers from here instead of writing their own.

/// The colours of the Imps' home: a cosy little dungeon, warm and friendly rather than scary.
///
/// These are fixed colours for the dark wall the app is drawn on, so they do not change with the
/// system appearance. Text and fills that should follow Light and Dark (the Mac's settings
/// buttons, say) use the system colours and read the colour scheme instead.
public enum Dungeon {
    public static let deep = Color(red: 0.12, green: 0.06, blue: 0.11)
    public static let wallTop = Color(red: 0.17, green: 0.08, blue: 0.15)
    public static let wallBottom = Color(red: 0.29, green: 0.10, blue: 0.13)
    public static let stone = Color(red: 0.42, green: 0.25, blue: 0.33)
    public static let stoneLight = Color(red: 0.55, green: 0.34, blue: 0.41)
    public static let doorway = Color(red: 0.07, green: 0.03, blue: 0.07)
    public static let ember = Color(red: 1.0, green: 0.62, blue: 0.26)
    public static let flame = Color(red: 1.0, green: 0.80, blue: 0.36)
    public static let cream = Color(red: 1.0, green: 0.95, blue: 0.88)
    /// Quiet text on the wall.
    public static let muted = Color(red: 1.0, green: 0.95, blue: 0.88).opacity(0.6)
    /// Cards and wells sitting on the wall.
    public static let card = Color.white.opacity(0.055)
    public static let cardEdge = Color.white.opacity(0.09)
    /// A dark well for text fields and editors.
    public static let well = Color.black.opacity(0.24)
    /// Connected, done, all well.
    public static let good = Color(red: 0.45, green: 0.85, blue: 0.55)

    /// The wall itself, darker at the top.
    public static var wall: LinearGradient {
        LinearGradient(colors: [wallTop, wallBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Corner radii, one scale for everything.
public enum Radius {
    /// Fields, small tiles and chips that are not capsules.
    public static let small: CGFloat = 8
    /// Cards on the Mac, selectable cards and wells.
    public static let medium: CGFloat = 14
    /// Cards on the iPhone and big panels.
    public static let large: CGFloat = 18
    /// Speech bubbles.
    public static let bubble: CGFloat = 22
}

/// Spacing, one scale for gaps and padding.
public enum Spacing {
    public static let hairline: CGFloat = 2
    public static let tight: CGFloat = 4
    public static let small: CGFloat = 8
    /// The gap between cards.
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    /// The padding around a page.
    public static let page: CGFloat = 20
    public static let huge: CGFloat = 28
}

/// Sizes of things you point at.
public enum Sizing {
    /// The smallest a control's hit area gets: 44 pt on the iPhone, 28 pt on the Mac.
    public static var hit: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    /// The height of a text field or a menu button.
    public static var control: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }
}

/// Type styles. On the iPhone they follow Dynamic Type, on the Mac they are fixed sizes.
public enum Typeface {
    private static func make(_ style: Font.TextStyle, _ size: CGFloat, _ weight: Font.Weight = .regular,
                             rounded: Bool = false, mono: Bool = false) -> Font {
        let design: Font.Design = mono ? .monospaced : (rounded ? .rounded : .default)
        #if os(iOS)
        return .system(style, design: design, weight: weight)
        #else
        return .system(size: size, weight: weight, design: design)
        #endif
    }

    /// A sheet's or screen's title.
    public static var title: Font { make(.title3, 17, .heavy, rounded: true) }
    /// A card's title.
    public static var cardTitle: Font { make(.headline, 14, .bold, rounded: true) }
    /// Ordinary text.
    public static var body: Font { make(.body, 13) }
    /// The label of a button or a chip.
    public static var label: Font { make(.subheadline, 12.5, .semibold, rounded: true) }
    /// A form label and other quiet lines.
    public static var caption: Font { make(.footnote, 12.5, .medium) }
    /// Small print, statuses and badges.
    public static var small: Font { make(.caption, 11.5) }
    /// Code, paths and keys.
    public static var mono: Font { make(.callout, 12.5, mono: true) }
}

/// How long things animate. Two lengths are enough.
public enum Timing {
    /// Hover, press, focus and other small changes.
    public static let short = 0.12
    /// Sliding, appearing and other changes you follow with your eyes.
    public static let medium = 0.25

    /// The short animation.
    public static var quick: Animation { .easeOut(duration: short) }
    /// The medium animation.
    public static var smooth: Animation { .snappy(duration: medium) }
}

private struct ImpAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animates changes of `value` unless Reduce Motion is on, when they just happen.
    public func impAnimation<Value: Equatable>(_ animation: Animation = Timing.quick, value: Value) -> some View {
        modifier(ImpAnimation(animation: animation, value: value))
    }
}

/// Runs `body` with `animation`, or with none when Reduce Motion is on. Pass the flag from
/// `@Environment(\.accessibilityReduceMotion)`.
@MainActor
public func withImpAnimation<Result>(_ animation: Animation = Timing.smooth, reduceMotion: Bool,
                                     _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? nil : animation, body)
}

extension EnvironmentValues {
    /// The colour of the Imp being shown: buttons, icons and highlights follow it.
    @Entry public var impTint: Color = Dungeon.ember
}
