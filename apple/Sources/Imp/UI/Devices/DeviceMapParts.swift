import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// A device on the canvas: a rounded card with its picture, name and state in the header. Its Imps are separate
/// nodes drawn over its lower part. Pressing it is the canvas's business (`DevicesCanvas`), so this only draws.
struct DeviceNodeCard: View {
    let id: String
    let node: DeviceMap.Node
    /// How the Hop stands, when this is the Hop.
    var hop: HopStanding?
    let hovered: Bool

    private var symbol: String { hop?.symbol ?? node.shownState.symbol }
    private var tone: Color { hop?.tone ?? node.shownState.tone }
    private var word: String { hop?.word ?? node.shownState.word }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        // An opaque ground first, so a line that passes under the card is not seen through it.
        shape.fill(Tone.surface)
            .overlay { shape.fill(hovered ? Tone.cardHover : Tone.card) }
            .overlay(alignment: .top) { header.opacity(node.shownState == .offline || hop == .off ? Opacity.dimmed : 1) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .trailing) { LinePoint(nodeID: id, id: DeviceGraph.Port.out, type: .source, side: .right) }
            .overlay(alignment: .leading) { LinePoint(nodeID: id, id: DeviceGraph.Port.in, type: .target, side: .left) }
            .overlay(alignment: .top) { LinePoint(nodeID: id, id: DeviceGraph.Port.tether(.top), type: .target, side: .top) }
            .overlay(alignment: .bottom) { LinePoint(nodeID: id, id: DeviceGraph.Port.tether(.bottom), type: .target, side: .bottom) }
            .contentShape(shape)
            .help("\(node.title): \(word)")
            .pointerStyle(.link)
    }

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: node.symbol).font(.icon(.medium)).foregroundStyle(Tone.text)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: node.title).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                if node.kind == .thisMac {
                    Text("devices.this_mac_badge").font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.icon(.tiny)).foregroundStyle(tone)
        }
        .padding(.horizontal, DeviceGraph.Metrics.padding)
        .frame(height: DeviceGraph.Metrics.header)
    }
}

/// An Imp inside a device: its colour and its name. One of this Mac's Imps has a full tint of its colour; a
/// visitor from another device has a lighter one and a small walking mark, so whose Imp it is can be seen at
/// a glance, without an outline.
struct DeviceImpChip: View {
    let id: String
    let name: String
    let hue: Double
    let ours: Bool
    let hovered: Bool
    let help: String

    var body: some View {
        HStack(spacing: Spacing.small) {
            Circle().fill(Color.imp(hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
            Text(verbatim: name).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(1)
            Spacer(minLength: 0)
            if !ours {
                Image(systemName: "figure.walk.arrival").font(.icon(.tiny)).foregroundStyle(Tone.muted).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.imp(hue).opacity(ours ? Opacity.tintFillStrong : Opacity.tintFill))
            .overlay { if hovered { RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card) } })
        .overlay(alignment: .top) { LinePoint(nodeID: id, id: DeviceGraph.Port.tether(.top), type: .source, side: .top) }
        .overlay(alignment: .bottom) { LinePoint(nodeID: id, id: DeviceGraph.Port.tether(.bottom), type: .source, side: .bottom) }
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .help(help)
        .pointerStyle(.link)
    }
}

/// Where a line attaches to a node, on one side of it: SwiftFlow measures it for the line's end. It draws nothing
/// (see the canvas theme) and neither takes presses nor is read out.
struct LinePoint: View {
    let nodeID: String
    let id: String
    let type: HandleType
    let side: Position

    var body: some View {
        Handle(nodeId: nodeID, id: id, type: type, position: side, isConnectable: false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A canvas path as a shape, so a line can be drawn as a filled outline (`DrawnLine`).
struct CanvasPath: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path { path }
}

/// One line of the canvas, drawn over SwiftFlow's own path so the hit area and the picture are the same line.
/// A channel is solid on the local network and dashed through the Hop; a tether is thin and in its Imp's colour.
/// A line that is not connected falls back. The tag sits beside the middle of it, never on it.
struct DeviceEdgeDrawing: View {
    let data: DeviceGraph.EdgeData
    let result: EdgePathResult
    let hovered: Bool

    private enum Metrics { static let tagClearance: CGFloat = 16 }

    var body: some View {
        ZStack {
            DrawnLine(shape: CanvasPath(path: result.path), style: style).fill(color)
                .opacity(data.dimmed ? Opacity.disabled : 1)
            if let tag = data.tag {
                Text(verbatim: tag).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                    .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.hairline)
                    .background(Capsule().fill(Tone.surface).overlay { Capsule().fill(Tone.card) })
                    .opacity(data.dimmed ? Opacity.disabled : 1)
                    .position(DeviceGraph.tagCenter(source: CGPoint(x: result.sourceX, y: result.sourceY),
                                                    target: CGPoint(x: result.targetX, y: result.targetY),
                                                    mid: CGPoint(x: result.labelX, y: result.labelY), clearance: Metrics.tagClearance))
            }
        }
        .help(data.label)
    }

    private var color: Color {
        if hovered { return Tone.accentBright }
        if case .tether(let hue) = data.look { return Color.imp(hue) }
        return Tone.muted
    }

    private var style: StrokeStyle {
        switch data.look {
        case .local: StrokeStyle(lineWidth: hovered ? 3 * Stroke.hairline : Stroke.focus, lineCap: .round)
        case .hop: StrokeStyle(lineWidth: hovered ? 3 * Stroke.hairline : Stroke.focus, lineCap: .round, dash: [Spacing.cozy, Spacing.small])
        case .tether: StrokeStyle(lineWidth: hovered ? Stroke.focus : Stroke.hairline, lineCap: .round)
        }
    }
}

/// A line drawn as a shape: the outline of `shape` swept with `style`, filled by the caller. A drawing, not
/// a control's outline.
struct DrawnLine<Base: Shape>: Shape {
    let shape: Base
    let style: StrokeStyle

    func path(in rect: CGRect) -> Path { shape.path(in: rect).strokedPath(style) }
}
