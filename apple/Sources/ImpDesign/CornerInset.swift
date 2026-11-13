import SwiftUI

/// Even corner insets (spec `cornerInset`). An icon button draws a `Sizing.glyph` circle inside a larger
/// `Sizing.hit` frame, so padding measured to the frame leaves the visible circle farther from the edge.
/// These helpers give the padding that puts the visible circle a given distance from an edge.
public enum CornerInset {
    /// How much room the hit frame has around the visible circle on each side.
    public static var slack: CGFloat { (Sizing.hit - Sizing.glyph) / 2 }

    /// The padding that sets the visible circle `visible` from an edge (never negative).
    public static func padding(visible: CGFloat) -> CGFloat { max(0, visible - slack) }

    /// The padding from the trailing (or leading) edge for a button centred in a bar `height` tall,
    /// so its trailing inset to the circle equals its top inset: (height - glyph) / 2 - (hit - glyph) / 2.
    public static func bar(height: CGFloat) -> CGFloat { padding(visible: (height - Sizing.glyph) / 2) }
}
