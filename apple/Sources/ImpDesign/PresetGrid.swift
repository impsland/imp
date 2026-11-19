import SwiftUI

// Choices laid out evenly: the same grid on the Mac and on the iPhone. `EvenGrid` makes every row span the
// full width with equal items (ten that need two rows go five and five).

/// Lays children out in rows that always fill the full width. Rows are balanced (ten items that
/// need two rows go five and five, never nine and one), and a shorter row stretches its items so
/// no row ends in an empty slot. Items in a row share its height.
public struct EvenGrid: Layout {
    var minWidth: CGFloat
    var maxColumns = Int.max
    var spacing: CGFloat = Spacing.small

    public init(minWidth: CGFloat, maxColumns: Int = .max, spacing: CGFloat = Spacing.small) {
        self.minWidth = minWidth
        self.maxColumns = maxColumns
        self.spacing = spacing
    }

    /// As wide as up to four columns at their narrowest: the size asked for when the width is open.
    private func naturalWidth(_ count: Int) -> CGFloat {
        (minWidth + spacing) * CGFloat(min(max(count, 1), 4)) - spacing
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, width: CGFloat, height: CGFloat)] {
        // SwiftUI also asks "how big at an endless width?": that is the natural width, not a crash
        // turning infinity into a column count.
        let width = width.isFinite ? width : naturalWidth(subviews.count)
        let fit = min(max(1, Int((width + spacing) / (minWidth + spacing))), maxColumns)
        var out: [(Range<Int>, CGFloat, CGFloat)] = []
        var start = 0
        for length in RowBalance.lineLengths(count: subviews.count, fit: fit) {
            let end = start + length
            let n = CGFloat(length)
            let w = max(0, (width - spacing * (n - 1)) / n)
            let h = subviews[start..<end].map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
            out.append((start..<end, w, h))
            start = end
        }
        return out
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth(subviews.count)
        let r = rows(width, subviews)
        let height = r.map(\.height).reduce(0, +) + spacing * CGFloat(max(r.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.range {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: row.width, height: row.height))
                x += row.width + spacing
            }
            y += row.height + spacing
        }
    }
}
