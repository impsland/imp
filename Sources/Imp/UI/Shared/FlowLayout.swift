import ImpKit
import SwiftUI

/// Wraps children onto new lines like text. Children never get wider than the container.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            var size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width + 0.5 {
                x = 0; y += rowH + lineSpacing; rowH = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
        let r = arrange(w, subviews)
        return CGSize(width: proposal.width ?? r.size.width, height: r.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        // Centre each item vertically within its line.
        var lines: [CGFloat: CGFloat] = [:]
        for f in r.frames { lines[f.minY] = max(lines[f.minY] ?? 0, f.height) }
        for (s, f) in zip(subviews, r.frames) {
            let dy = ((lines[f.minY] ?? f.height) - f.height) / 2
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY + dy),
                    anchor: .topLeading, proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}
