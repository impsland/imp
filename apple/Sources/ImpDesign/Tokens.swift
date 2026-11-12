import SwiftUI

// The look every Imp screen shares, on the Mac and on the iPhone: one palette, one scale of
// corners, one scale of spacing, a few type styles and a set of named animations. Screens take
// their numbers from here instead of writing their own.

/// The palette is generated into `Tone` (`Tokens.generated.swift`), with `Radius`, `Spacing`,
/// `Sizing`, `TypeScale`, `Timing`, `Motion` and `Behavior`, from `design/tokens.json`. This file
/// holds what is not a plain number.

/// What is drawn on a coloured control (a filled button, the chosen segment, a switch that is
/// on): white or black. The person chooses it once for the whole app, and white is the default.
public enum TintInk: String, CaseIterable, Sendable {
    case white, black
}

extension EnvironmentValues {
    /// The fill and the foreground of a coloured control of `tint` (the Imp's tint when nil), by
    /// the one rule in `Contrast.control`. `TintFill` and `OnTint` are its two halves.
    fileprivate func control(_ tint: Color?) -> Contrast.Control {
        let ink = ContrastColor(Tone.ink, in: self), paper = ContrastColor(Tone.paper, in: self)
        return Contrast.control(ContrastColor(tint ?? impTint, in: self), chosen: tintInk == .white ? paper : ink,
                                ink: ink, paper: paper)
    }
}

/// The fill of a coloured control: the colour itself when the chosen white or black reads on it
/// with at least 4.5 to 1, else the nearest shade of it that does (deeper under white, lighter
/// under black). So white on a yellow or green Imp sits on a deeper yellow or green instead of
/// being lost. With no colour given it follows the Imp's tint.
public struct TintFill: ShapeStyle {
    let tint: Color?

    public init(_ tint: Color? = nil) { self.tint = tint }

    public func resolve(in environment: EnvironmentValues) -> Color {
        environment.control(tint).fill.color
    }
}

/// Text, icons and switch knobs on a `TintFill` of the same colour: the white or black the person
/// chose (`EnvironmentValues.tintInk`), on every coloured control. Never `Tone.text`, which is ink
/// in the light theme and would be ink on ink.
public struct OnTint: ShapeStyle {
    let tint: Color?

    public init(_ tint: Color? = nil) { self.tint = tint }

    public func resolve(in environment: EnvironmentValues) -> Color {
        environment.control(tint).foreground.color
    }
}

/// One entry of the type scale: a size and weight on the Mac, a text style on the iPhone.
public struct TypeToken: Sendable {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let style: Font.TextStyle

    var font: Font {
        #if os(iOS)
        .system(style, design: design, weight: weight)
        #else
        .system(size: size, weight: weight, design: design)
        #endif
    }
}

/// Type styles. On the iPhone they follow Dynamic Type, on the Mac they are fixed sizes.
public enum Typeface {
    /// A sheet's or screen's title.
    public static var title: Font { TypeScale.title.font }
    public static var display: Font { TypeScale.display.font }
    /// A card's title.
    public static var cardTitle: Font { TypeScale.cardTitle.font }
    /// Ordinary text.
    public static var body: Font { TypeScale.body.font }
    /// The label of a button or a chip.
    public static var label: Font { TypeScale.label.font }
    /// A form label and other quiet lines.
    public static var caption: Font { TypeScale.caption.font }
    /// Small print, statuses and badges.
    public static var small: Font { TypeScale.small.font }
    /// Code, paths and keys.
    public static var mono: Font { TypeScale.mono.font }
}

extension Font {
    /// An icon's font from the icon scale. On the iPhone it grows with its text style (Dynamic Type),
    /// on the Mac it is the token's fixed size.
    public static func icon(_ size: IconSize, weight: Font.Weight = .semibold) -> Font {
        #if os(iOS)
        .system(size.textStyle, weight: weight)
        #else
        .system(size: size.points, weight: weight)
        #endif
    }
}

/// A named animation, and what it becomes when Reduce Motion is on: nothing (`nil`) or a short fade.
public struct MotionPreset: Sendable {
    public let animation: Animation
    public let reduced: Animation?

    init(_ animation: Animation, reduced: Animation?) {
        self.animation = animation
        self.reduced = reduced
    }
}

extension Timing {
    /// The short animation.
    public static var quick: Animation { Motion.quick.animation }
    /// The medium animation.
    public static var smooth: Animation { Motion.smooth.animation }
}

private struct ImpAnimation<Value: Equatable>: ViewModifier {
    let preset: MotionPreset?
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let used = reduceMotion ? preset?.reduced : (preset?.animation ?? animation)
        content.animation(used, value: value)
    }
}

extension View {
    /// Animates changes of `value` with a named animation. With Reduce Motion on it fades or just happens,
    /// as the preset says.
    public func impAnimation<Value: Equatable>(_ preset: MotionPreset = Motion.quick, value: Value) -> some View {
        modifier(ImpAnimation(preset: preset, animation: nil, value: value))
    }

    /// Animates changes of `value` unless Reduce Motion is on, when they just happen.
    public func impAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(ImpAnimation(preset: nil, animation: animation, value: value))
    }
}

/// Runs `body` with a named animation. With Reduce Motion on it fades or just happens, as the
/// preset says. Pass the flag from `@Environment(\.accessibilityReduceMotion)`.
@MainActor
public func withImpAnimation<Result>(_ preset: MotionPreset = Motion.smooth, reduceMotion: Bool,
                                     _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? preset.reduced : preset.animation, body)
}

/// Runs `body` with `animation`, or with none when Reduce Motion is on.
@MainActor
public func withImpAnimation<Result>(_ animation: Animation, reduceMotion: Bool,
                                     _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? nil : animation, body)
}

extension EnvironmentValues {
    /// The colour of the Imp being shown: buttons, icons and highlights follow it.
    @Entry public var impTint: Color = Tone.accent
    /// White or black on coloured controls: the person's choice, set at the root of every window.
    @Entry public var tintInk: TintInk = .white
}

extension MotionPreset {
    /// The animation, or what it becomes with Reduce Motion on.
    public func reducedAware(_ reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : animation }
}

/// A user-facing sentence from design/strings with its numbered values filled in.
public func words(_ resource: LocalizedStringResource, _ values: CVarArg...) -> String {
    String(format: String(localized: resource), arguments: values)
}
