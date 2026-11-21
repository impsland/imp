import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// A device on the canvas: a rounded card with its picture, name and state in the header. Its Imps are separate
/// nodes drawn over its lower part. Pressing it is the canvas's business (`DevicesCanvas`), so this only draws.
struct DeviceNodeCard: View {
    let id: String
    let node: DeviceMap.Node
    let hovered: Bool
    /// What it says when hovered, and to a screen reader.
    let help: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        // An opaque ground first, so a line that passes under the card is not seen through it.
        shape.fill(Tone.surface)
            .overlay { shape.fill(hovered ? Tone.cardHover : Tone.card) }
            .overlay(alignment: .top) { header.opacity(node.shownState == .offline ? Opacity.dimmed : 1) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { LinePoints(nodeID: id, ports: { DeviceGraph.Port.line($0, $1) }) }
            .overlay { LinePoints(nodeID: id, sides: DeviceGraph.Port.tetherSides, types: [.target], ports: { side, _ in DeviceGraph.Port.tether(side) }) }
            .contentShape(shape)
            .help(help)
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
            // A device known only through another has no state of its own: it is drawn dimmed and joined by a dotted line.
            if node.linked { Image(systemName: node.shownState.symbol).font(.icon(.tiny)).foregroundStyle(node.shownState.tone) }
        }
        .padding(.horizontal, DeviceGraph.Metrics.padding)
        .frame(height: DeviceGraph.Metrics.header)
    }
}

/// An Imp inside a device: its colour and its name. One of this Mac's Imps has a full tint of its colour. Another
/// device's Imp has a lighter one, so whose Imp it is can be seen at a glance, without an outline. An Imp whose
/// body is not where it thinks wears a tiny glyph of its home device (`home`), so where it lives is seen without a line.
struct DeviceImpChip: View {
    let id: String
    let name: String
    let hue: Double
    let ours: Bool
    /// The symbol of the home device of an Imp that is away.
    let home: String?
    let hovered: Bool
    let help: String

    var body: some View {
        HStack(spacing: Spacing.small) {
            Circle().fill(Color.imp(hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
            Text(verbatim: name).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            if let home {
                HStack(spacing: Spacing.hairline) {
                    Image(systemName: "house.fill").font(.icon(.tiny))
                    Image(systemName: home).font(.icon(.tiny))
                }
                .foregroundStyle(Tone.muted).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.imp(hue).opacity(ours ? Opacity.tintFillStrong : Opacity.tintFill))
            .overlay { if hovered { RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card) } })
        .overlay { LinePoints(nodeID: id, sides: DeviceGraph.Port.tetherSides, types: [.source], ports: { side, _ in DeviceGraph.Port.tether(side) }) }
        .overlay { LinePoints(nodeID: id, sides: [.left, .right], ports: { DeviceGraph.Port.talk($0, $1) }) }
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .help(help)
        .pointerStyle(.link)
    }
}

/// The points of a node where lines attach, on the sides given, each as a source and a target unless `types` says
/// otherwise; `ports` names the point for a side and a type.
struct LinePoints: View {
    let nodeID: String
    var sides: [Position] = DeviceGraph.Port.sides
    var types: [HandleType] = [.source, .target]
    let ports: (Position, HandleType) -> String

    var body: some View {
        ZStack {
            ForEach(sides, id: \.self) { side in
                ForEach(types, id: \.self) { type in
                    LinePoint(nodeID: nodeID, id: ports(side, type), type: type, side: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(side))
                }
            }
        }
    }

    private static func alignment(_ side: Position) -> Alignment {
        switch side {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
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

/// One line of the canvas, drawn over SwiftFlow's own path so the hit area and the picture are the same line. One
/// visual language, no text: a channel is solid on the local network and dashed through the Hop, a device known only
/// through another hangs on a thin dotted line, a tether is thin and in its Imp's colour and a talk line thin and
/// dashed in it. A line that is not connected is faint. Small dots run along a line that is live and in focus
/// (`motion`), both ways on a channel and from the Imp to its home on a tether.
struct DeviceEdgeDrawing: View {
    let data: DeviceGraph.EdgeData
    let result: EdgePathResult
    let hovered: Bool
    /// Whether the line is in the light, in the current focus. The rest is drawn dimmed.
    let lit: Bool
    /// Whether something is in focus and this line is part of it: only those lines move.
    let focused: Bool
    let motion: Bool

    private enum Metrics {
        /// Seconds a dot takes along a line.
        static let period: Double = 5
        static let dotsPerWay = 2
        static let fps: Double = 24
    }

    var body: some View {
        ZStack {
            DrawnLine(shape: CanvasPath(path: result.path), style: style).fill(color)
                .opacity(data.dimmed ? Opacity.disabled : 1)
            if motion, focused, data.live { dots }
        }
        .opacity(lit ? 1 : Opacity.dimmed)
        .help(data.label)
    }

    private var dotColor: Color {
        switch data.look {
        case .tether(let hue), .talk(let hue): Color.imp(hue)
        case .local, .hop, .relay: Tone.accentBright
        }
    }

    private var dots: some View {
        TimelineView(.animation(minimumInterval: Energy.shared.interval(fps: Metrics.fps))) { context in
            let time = context.date.timeIntervalSinceReferenceDate / Metrics.period
            let both = !data.isTether
            let count = both ? Metrics.dotsPerWay : 1
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    dot(at: (time + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1))
                    if both { dot(at: 1 - (time + 0.5 / Double(count) + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dot(at fraction: Double) -> some View {
        let point = result.path.trimmedPath(from: 0, to: min(1, max(0.001, fraction))).currentPoint ?? .zero
        return Circle().fill(dotColor).frame(width: Spacing.tight, height: Spacing.tight).position(point)
    }

    private var color: Color {
        if hovered { return Tone.accentBright }
        switch data.look {
        case .tether(let hue), .talk(let hue): return Color.imp(hue)
        case .local, .hop, .relay: return Tone.muted
        }
    }

    private var style: StrokeStyle {
        switch data.look {
        case .local: StrokeStyle(lineWidth: hovered ? 3 * Stroke.hairline : Stroke.focus, lineCap: .round)
        case .hop: StrokeStyle(lineWidth: hovered ? 3 * Stroke.hairline : Stroke.focus, lineCap: .round, dash: [Spacing.cozy, Spacing.small])
        case .relay: StrokeStyle(lineWidth: Stroke.hairline, lineCap: .round, dash: [Stroke.hairline, Spacing.small])
        case .tether: StrokeStyle(lineWidth: hovered ? Stroke.focus : Stroke.hairline, lineCap: .round)
        case .talk: StrokeStyle(lineWidth: Stroke.focus, lineCap: .round, dash: [Spacing.tight, Spacing.small])
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
