import CoreGraphics

/// The home window's smallest size: a setting (App › Window), not a fixed layout size. Every screen
/// in the window adapts to whatever size it is above this. Pure, so it is tested without a window.
///
/// Which values are design tokens and which are settings: the layout breakpoint below which Imp
/// Settings shows its plain list (`Behavior.narrowWindowPoints`) is a design token, because it is
/// where the design itself changes. The smallest window is the person's choice, within `widths`
/// and `heights`. A minimum below the breakpoint simply lets the narrow layout show.
public enum WindowSizing {
    /// The smallest window until the person changes it, in points.
    public static let defaultMinimum = CGSize(width: 660, height: 540)
    /// What the setting allows, in points: small enough for the narrow layout, large enough for any screen.
    public static let widths: ClosedRange<Double> = 400...1200
    public static let heights: ClosedRange<Double> = 420...900
    /// The size the window opens at the very first time, grown to the minimum if that is larger
    /// (`opening(minimum:)`). After that the window keeps the size the person gave it.
    public static let firstOpen = CGSize(width: 780, height: 640)

    /// The slider's step, in points.
    public static let step: Double = 20

    /// `size` within the allowed range (anything not a number is the default).
    public static func clamped(_ size: CGSize) -> CGSize {
        let w = size.width.isFinite ? Double(size.width) : Double(defaultMinimum.width)
        let h = size.height.isFinite ? Double(size.height) : Double(defaultMinimum.height)
        return CGSize(width: min(max(w, widths.lowerBound), widths.upperBound),
                      height: min(max(h, heights.lowerBound), heights.upperBound))
    }

    /// The size the window opens at the very first time.
    public static func opening(minimum: CGSize) -> CGSize { fitted(firstOpen, minimum: minimum) }

    /// The window's content size after the minimum changed: as it is, grown where it is now smaller.
    public static func fitted(_ current: CGSize, minimum: CGSize) -> CGSize {
        CGSize(width: max(current.width, minimum.width), height: max(current.height, minimum.height))
    }
}
