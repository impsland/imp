import CoreGraphics

/// The sizes the home window can be given from Settings (App › Window).
public enum WindowPreset: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    /// As large as the screen allows.
    case full
}

/// The home window's sizes. The smallest the window can be is a fixed design value (`minimum`), not a
/// setting; a person picks one of a few standard sizes (`WindowPreset`) and may still resize by hand.
/// Pure, so it is tested without a window or a screen.
///
/// The layout breakpoint below which Imp Settings shows its plain list (`Behavior.narrowWindowPoints`)
/// is a design token. `minimum` lies below it, so the narrow layout can always be reached.
public enum WindowSizing {
    /// The smallest the window can be made, in points.
    public static let minimum = CGSize(width: 440, height: 480)
    /// The preset until one is chosen, and the size the window opens at the first time.
    public static let standard = WindowPreset.medium

    /// A preset's window size on a screen, in points. Never larger than `visible`, never below `minimum`
    /// (unless the screen itself is smaller than that).
    public static func size(of preset: WindowPreset, in visible: CGSize) -> CGSize {
        let wanted: CGSize
        switch preset {
        case .small: wanted = CGSize(width: 560, height: 520)
        case .medium: wanted = CGSize(width: 780, height: 640)
        case .large: wanted = CGSize(width: 1040, height: 780)
        case .full: return visible
        }
        return CGSize(width: min(max(wanted.width, minimum.width), visible.width),
                      height: min(max(wanted.height, minimum.height), visible.height))
    }

    /// The window's frame after choosing `preset`: the new size with the window's top left corner kept
    /// where it is, then moved just enough to lie inside `visible` (the screen minus menu bar and Dock).
    public static func frame(for preset: WindowPreset, from current: CGRect, in visible: CGRect) -> CGRect {
        let size = size(of: preset, in: visible.size)
        var x = current.minX
        var top = current.maxY                       // AppKit's origin is bottom left
        x = min(max(x, visible.minX), visible.maxX - size.width)
        top = min(max(top, visible.minY + size.height), visible.maxY)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}
