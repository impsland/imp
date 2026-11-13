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
    public static func bar(height: CGFloat) -> CGFloat { row(height: height, top: 0) }

    /// The side padding for a button centred in a row `height` tall that starts `top` below the edge (a
    /// sheet's header, whose icon tile is taller than the button): the circle's side inset equals its top inset.
    public static func row(height: CGFloat, top: CGFloat) -> CGFloat { padding(visible: top + (height - Sizing.glyph) / 2) }
}

extension View {
    /// Sets a corner item that is not an icon button (a version, a count) as far from the `edge` as from the
    /// top of a bar `height` tall. The bar pads its sides for an icon button (`CornerInset.bar`), whose
    /// visible circle is centred; a label's visible box is its own line, so it gets the difference on that
    /// side, measured from its own height. Top inset and side inset come out equal at any text size.
    public func cornerLabel(_ edge: HorizontalEdge, bar height: CGFloat) -> some View {
        modifier(CornerLabel(edge: edge, bar: height))
    }
}

private struct CornerLabel: ViewModifier {
    let edge: HorizontalEdge
    let bar: CGFloat
    @State private var own: CGFloat = 0

    func body(content: Content) -> some View {
        let extra = max(0, (bar - own) / 2 - CornerInset.bar(height: bar))
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { own = $0 }
            .padding(edge == .leading ? .leading : .trailing, own == 0 ? 0 : extra)
    }
}
