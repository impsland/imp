import CoreGraphics

/// Where a long reply is cut when it's collapsed behind "Read all": never through a picture or video.
public enum ReadAllCut {
    /// A picture or video block's top and bottom, measured from the top of the reply's text area.
    public struct Span: Equatable, Sendable {
        public var top: CGFloat
        public var bottom: CGFloat
        public init(top: CGFloat, bottom: CGFloat) { self.top = top; self.bottom = bottom }
        var height: CGFloat { bottom - top }
    }

    /// What's left below a picture that isn't worth a "Read all" of its own.
    public static let smallTail: CGFloat = 60

    /// How tall to show a reply's text: `cap` is where it would be cut, `most` the most room there is.
    /// A cut inside a picture moves to its bottom (if that fits, or the whole reply does when only
    /// a little follows) or up to its top. `nil` shows it all.
    public static func limit(textHeight: CGFloat, spans: [Span], cap: CGFloat, most: CGFloat) -> CGFloat? {
        guard let block = spans.first(where: { $0.top < cap && cap < $0.bottom }),
              block.height <= most else { return cap }      // clear of pictures, or one too tall to help
        if block.bottom <= most {
            if textHeight - block.bottom < smallTail, textHeight <= most { return nil }
            return block.bottom
        }
        return block.top >= 40 ? block.top : cap            // nothing worth showing above it
    }
}
