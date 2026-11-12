import SwiftUI

// The maths behind legible colour, with no views in it: relative luminance, contrast ratio (WCAG 2),
// the shade of a fill that carries the chosen white or black, and the nudge that makes an Imp's
// colour readable as text or an icon on the surface. `TintFill`, `OnTint` and `LegibleTint` are the
// ShapeStyles that use it. design/components.json ("tintFill", "onTint", "legibleTint") says the
// same in words for the other platforms.

/// A colour as plain numbers: red, green and blue encoded as sRGB (0...1) and an opacity.
public struct ContrastColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A colour as it is drawn in `environment`: its light or dark value, as the screen shows it.
    public init(_ color: Color, in environment: EnvironmentValues) {
        let c = color.resolve(in: environment)
        self.init(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))
    }

    /// The colour as a SwiftUI colour.
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance, 0 (black) to 1 (white). Ignores opacity: composite with `over` first.
    public var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// This colour laid on `ground`, the way the screen blends it.
    public func over(_ ground: ContrastColor) -> ContrastColor {
        guard alpha < 1 else { return self }
        let a = alpha
        return ContrastColor(red: red * a + ground.red * (1 - a), green: green * a + ground.green * (1 - a),
                             blue: blue * a + ground.blue * (1 - a), alpha: 1)
    }

    /// This colour moved `amount` (0...1) of the way to `other`, keeping its opacity.
    public func mixed(toward other: ContrastColor, by amount: Double) -> ContrastColor {
        ContrastColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                      blue: blue + (other.blue - blue) * amount, alpha: alpha)
    }

    /// No hue to speak of: a grey, black, white, or the app's ink and paper.
    public var isNeutral: Bool {
        max(red, green, blue) - min(red, green, blue) < 0.08
    }

    public static let black = ContrastColor(red: 0, green: 0, blue: 0)
    public static let white = ContrastColor(red: 1, green: 1, blue: 1)
}

public enum Contrast {
    /// Text needs this ratio against what it sits on (WCAG AA).
    public static let text = 4.5
    /// Icons, state shapes and controls need this one.
    public static let graphic = 3.0

    /// The contrast ratio of two opaque colours, 1 (same) to 21 (black on white).
    public static func ratio(_ a: ContrastColor, _ b: ContrastColor) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The ratio of `foreground` laid on `ground`. A see-through foreground is blended first.
    public static func ratio(_ foreground: ContrastColor, on ground: ContrastColor) -> Double {
        ratio(foreground.over(ground), ground)
    }

    /// Whether ink (rather than paper) reads better on `fill`: whichever has the higher ratio.
    public static func prefersInk(on fill: ContrastColor, ink: ContrastColor, paper: ContrastColor) -> Bool {
        ratio(ink, fill) >= ratio(paper, fill)
    }

    /// A coloured control: its fill and what is drawn on it.
    public struct Control: Equatable, Sendable {
        public var fill: ContrastColor
        public var foreground: ContrastColor
    }

    /// The one rule for every coloured control. `chosen` is the white or black the person picked.
    ///
    /// A fill with a hue (an Imp's colour) carries `chosen`, always. The fill is used as it is when
    /// `chosen` reads on it with at least `minimum`, else it moves away from `chosen` (toward black
    /// under white, toward white under black) by the least that reaches `minimum`, keeping its hue.
    ///
    /// A fill with no hue (the monochrome accent, which is paper in dark and ink in light) has no
    /// colour to keep and would only turn grey: it stays as it is and carries ink or paper,
    /// whichever reads better (pure black or white on a mid grey, where neither reaches `minimum`).
    public static func control(_ tint: ContrastColor, chosen: ContrastColor, ink: ContrastColor, paper: ContrastColor,
                               minimum: Double = Contrast.text) -> Control {
        if tint.isNeutral {
            let best = prefersInk(on: tint, ink: ink, paper: paper) ? ink : paper
            if ratio(best, tint) >= minimum { return Control(fill: tint, foreground: best) }
            // A grey in the middle of the range, where ink and paper are not extreme enough: pure
            // black or white, one of which always reaches 4.58.
            return Control(fill: tint, foreground: ratio(.black, tint) >= ratio(.white, tint) ? .black : .white)
        }
        let fill = legible(tint, on: chosen, lighten: chosen.luminance < 0.5, minimum: minimum)
        return Control(fill: fill, foreground: chosen)
    }

    /// `tint` as text or an icon on `ground`: unchanged when it already reads, else moved toward white
    /// (`lighten`, on a dark ground) or black (on a light one) by the least that reaches `minimum`.
    /// The hue is kept as far as it can be.
    public static func legible(_ tint: ContrastColor, on ground: ContrastColor, lighten: Bool,
                               minimum: Double = Contrast.text) -> ContrastColor {
        let solid = tint.over(ground)
        if ratio(solid, ground) >= minimum { return solid }
        let end: ContrastColor = lighten ? .white : .black
        var low = 0.0, high = 1.0
        guard ratio(end, ground) >= minimum else { return end }
        // A hair over the minimum: a colour is stored as 32-bit floats when it is drawn, which can
        // cost a few millionths of a ratio.
        let target = minimum + 0.01
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if ratio(solid.mixed(toward: end, by: mid), ground) >= target { high = mid } else { low = mid }
        }
        return solid.mixed(toward: end, by: high)
    }
}

/// What a legible Imp colour sits on.
public enum LegibleGround: Sendable {
    /// A screen, a sheet or a card (a card is a faint veil on the surface).
    case surface
    /// A popover, a menu, the undo bar.
    case raised
}

/// An Imp's colour as text or an icon: the colour itself when it reads on the surface, else a
/// lighter (in dark) or darker (in light) shade of it with at least 4.5 to 1. An Imp can be nearly
/// black or nearly white, so the raw colour is only for fills (with `OnTint` on top). With no
/// colour given it follows the Imp's tint.
public struct LegibleTint: ShapeStyle {
    let tint: Color?
    let ground: LegibleGround

    public init(_ tint: Color? = nil, on ground: LegibleGround = .surface) {
        self.tint = tint
        self.ground = ground
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        let ground = ContrastColor(self.ground == .raised ? Tone.raised : Tone.surface, in: environment)
        let source = ContrastColor(tint ?? environment.impTint, in: environment)
        return Contrast.legible(source, on: ground, lighten: environment.colorScheme == .dark).color
    }
}

extension Color {
    /// This colour as text or an icon on the surface: see `LegibleTint`.
    public func legible(on ground: LegibleGround = .surface) -> LegibleTint { LegibleTint(self, on: ground) }
}
