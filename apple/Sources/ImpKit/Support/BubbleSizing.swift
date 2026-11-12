import Foundation

/// How big the full bubble (the chat) may be, and where it may sit. Pure, so it is tested without a screen.
public enum BubbleSizing {
    /// The size a chat bubble opens at until the user resizes it (the card, without its transparent margin).
    public static let defaultSize = CGSize(width: 440, height: 520)
    public static let minimum = CGSize(width: 320, height: 320)
    /// Room kept free at the screen's edges for the card's margin and the corner buttons.
    public static let reserve = CGSize(width: 56, height: 72)

    /// Lines the input may grow to before it scrolls, and the range the setting allows.
    public static let defaultInputLines = 6
    public static let inputLines = 2...12

    public static func clampedLines(_ lines: Int) -> Int { min(max(lines, inputLines.lowerBound), inputLines.upperBound) }

    /// `size` within the minimum and the visible screen (less `reserve`). On a screen too small for
    /// the minimum, the screen wins.
    public static func clamped(_ size: CGSize, visible: CGSize, minimum: CGSize = minimum, reserve: CGSize = reserve) -> CGSize {
        let maxW = max(visible.width - reserve.width, 1), maxH = max(visible.height - reserve.height, 1)
        let w = size.width.isFinite ? size.width : defaultSize.width
        let h = size.height.isFinite ? size.height : defaultSize.height
        return CGSize(width: min(max(w, min(minimum.width, maxW)), maxW),
                      height: min(max(h, min(minimum.height, maxH)), maxH))
    }

    /// `frame` moved so the card (the frame less `margin` all round) stays on `visible`, and its top
    /// stays below `topLimit`.
    public static func onScreen(_ frame: CGRect, visible: CGRect, margin: CGFloat, topLimit: CGFloat) -> CGRect {
        var f = frame
        let minX = visible.minX - margin + 4, minY = visible.minY - margin
        f.origin.x = min(max(f.origin.x, minX), max(visible.maxX - f.width + margin - 4, minX))
        f.origin.y = min(max(f.origin.y, minY), max(topLimit - f.height, minY))
        return f
    }
}
