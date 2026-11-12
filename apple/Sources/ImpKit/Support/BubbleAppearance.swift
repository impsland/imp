import Foundation

/// How the speech bubble above an Imp is filled on the Mac: the solid `Tone.raised`, or the same
/// colour at an opacity over a blur of what is behind it. Only the fill is ever translucent.
/// (The phone's bubble sits over the app's own stage, so it has no such setting.)
public struct BubbleAppearance: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable { case solid, translucent }

    /// The same numbers as `Opacity.bubbleMin` and `Opacity.bubbleDefault` in `design/tokens.json`
    /// (ImpKit does not see ImpDesign; a test in the Mac app's tests keeps them equal).
    public static let minimumOpacity = 0.4
    public static let defaultOpacity = 0.75

    public var style: Style = .solid
    public var opacity: Double = BubbleAppearance.defaultOpacity {
        didSet { opacity = Self.clamped(opacity) }
    }

    public init(style: Style = .solid, opacity: Double = BubbleAppearance.defaultOpacity) {
        self.style = style
        self.opacity = Self.clamped(opacity)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: try c.decodeIfPresent(Style.self, forKey: .style) ?? .solid,
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity)
    }

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(max(value, minimumOpacity), 1)
    }

    /// How opaque the fill is drawn: 1 for solid, and also when the system asks for less
    /// transparency or more contrast, or when there is no blur to keep the text legible.
    public func fillOpacity(reduceTransparency: Bool, increaseContrast: Bool, canBlur: Bool = true) -> Double {
        guard style == .translucent, !reduceTransparency, !increaseContrast, canBlur else { return 1 }
        return opacity
    }
}
