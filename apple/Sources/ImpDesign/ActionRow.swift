import SwiftUI

/// A row of actions that is always balanced (spec `actionRow`): a lone action is centred (a wide one spans
/// the row), never left at one side with empty room on the other. With more, the last one (the main action) holds the trailing
/// edge and the others start at the leading edge, so the row reads from its first action to its main one.
/// It replaces an `HStack` with a `Spacer`: give it the actions only.
public struct ActionRow: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = Spacing.small) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let main = subviews.last else { return }
        if subviews.count == 1 {
            // Offered the whole width: a wide button fills it, a pill keeps its size in the middle.
            main.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        let mainSize = main.sizeThatFits(.unspecified)
        main.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(mainSize))
        // The others share what the main action leaves; one that stretches (a status line) takes the rest.
        let end = bounds.maxX - mainSize.width - spacing
        var x = bounds.minX
        for view in subviews.dropLast() {
            let offer = ProposedViewSize(width: max(0, end - x), height: nil)
            let size = view.sizeThatFits(offer)
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: size.width, height: nil))
            x += size.width + spacing
        }
    }
}
