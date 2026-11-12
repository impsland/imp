import SwiftUI

// Preset choices laid out evenly: the same grid on the Mac and on the iPhone. `EvenGrid` makes every
// row span the full width with equal items (ten that need two rows go five and five). `PresetTile` is a
// preset that picks on a tap and has a small arrow that opens its page (the service choices, Remote and
// Local, in the first run and in Add a service):
//
//     EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) { ForEach(presets) { PresetTile(...) } }

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

/// One preset choice as a tile: its symbol, a title ("Remote", "Local"), and a detail (the service it
/// fills in), with a small ↗ in its corner that opens `link` (where to get a key or a model) without
/// choosing it. Picked, it fills with the Imp's colour. `found` adds a dot: it answers on this computer.
public struct PresetTile: View {
    let symbol: String
    let title: String
    let detail: String
    let picked: Bool
    let found: Bool
    let foundHelp: String
    let link: URL
    let linkHelp: String
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.openURL) private var openURL
    @State private var hover = false
    @State private var hoverLink = false

    public init(symbol: String, title: String, detail: String, picked: Bool, found: Bool = false, foundHelp: String = "",
                link: URL, linkHelp: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.picked = picked
        self.found = found; self.foundHelp = foundHelp; self.link = link; self.linkHelp = linkHelp; self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        Button(action: action) {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: symbol)
                    .font(.icon(.large, weight: .semibold))
                    .frame(width: Sizing.iconTile, height: Sizing.iconTile)
                    .background(Circle().fill(picked ? AnyShapeStyle(OnTint(tint).opacity(Opacity.tintFill)) : AnyShapeStyle(Tone.well)))
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.snug) {
                        Text(verbatim: title).font(Typeface.cardTitle).lineLimit(1)
                        if found {
                            Circle().fill(Tone.good).frame(width: Spacing.snug, height: Spacing.snug)
                                .help(foundHelp).accessibilityLabel(foundHelp)
                        }
                    }
                    if !detail.isEmpty {
                        Text(verbatim: detail).font(Typeface.small).lineLimit(1)
                            .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
                    }
                }
                Spacer(minLength: Sizing.mark)
            }
            .padding(Spacing.cozy)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            Button { openURL(link) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.icon(.small, weight: .bold))
                    .frame(width: Sizing.mark, height: Sizing.mark)
                    .background(Circle().fill(hoverLink ? Tone.cardHover : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(Spacing.snug)
            .onHover { hoverLink = $0 }
            .help(linkHelp)
            .accessibilityLabel(linkHelp)
        }
        .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
        .background(shape.fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.cardHover : Tone.card)))
        .onHover { hover = $0 }
        .impAnimation(Motion.hover, value: hover)
        .impAnimation(Motion.hover, value: hoverLink)
        .impAnimation(Motion.quick, value: picked)
    }
}
