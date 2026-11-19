import CoreGraphics

/// Evens out recorded frames so that a sticker's frames can share keyframes: the same shape keeps the same
/// number of points from one frame to the next, and a path drawn several times over (a fill and the light
/// on it) is one path with several paints.
enum StickerShapes {
    /// A path and what is painted with it, back to front.
    struct Item {
        var path: CGPath
        var paints: [VectorShape]
        /// The path as it was drawn, to know a path drawn again.
        var drawn: CGPath
        /// The part it is, from one frame to the next.
        var track: String { paints[0].track }
    }

    /// Long outlines (the head is a fine polyline) are drawn with this many points, smoothly.
    static let longOutline = 16
    /// Outlines cut by a clip, or merged from many pieces, whose points change from frame to frame, get this many.
    static let cutOutline = 12

    static func items(_ frames: [[VectorShape]]) -> [[Item]] {
        frames.map { shapes in
            var items: [Item] = []
            for shape in shapes {
                if let last = items.last, last.drawn == shape.path, (last.paints[0].stroke == nil) == (shape.stroke == nil) {
                    items[items.count - 1].paints.append(shape)
                } else if let last = items.last, last.paints.count == 1, Self.samePaint(last.paints[0], shape) {
                    // Small things painted alike (the dots of a blush, a glyph's pieces) are one path.
                    let joined = CGMutablePath()
                    joined.addPath(last.path)
                    joined.addPath(shape.stroke == nil ? even(shape) : shape.path)
                    items[items.count - 1].path = joined
                    items[items.count - 1].drawn = joined
                } else {
                    items.append(Item(path: shape.stroke == nil ? even(shape) : shape.path, paints: [shape], drawn: shape.path))
                }
            }
            return items
        }
    }

    /// Tiny dots of the same flat colour at the same opacity (the dots of a blush).
    static func samePaint(_ a: VectorShape, _ b: VectorShape) -> Bool {
        guard a.stroke == nil, b.stroke == nil, case .color(let x) = a.paint, case .color(let y) = b.paint, x == y,
              abs(a.opacity - b.opacity) < 0.002 else { return false }
        let tiny = { (s: VectorShape) in s.path.boundingBoxOfPath.width < 12 && s.path.boundingBoxOfPath.height < 12 }
        return tiny(a) && tiny(b)
    }

    /// The shape's path with a steady number of points: an outline cut by a clip, or one of many points,
    /// is traced again with a fixed number of smooth points. Others are kept as drawn.
    static func even(_ shape: VectorShape) -> CGPath {
        var parts = LottieWriter.subpaths(shape.path)
        // A shape built from many overlapping pieces (a horn is a band of them) is drawn as its one outline.
        var merged = false
        if parts.filter(\.closed).count > 2 {
            parts = LottieWriter.subpaths(shape.path.normalized(using: .winding))
            merged = true
        }
        let redraw = shape.clipped || merged
        guard parts.contains(where: { $0.closed && (redraw || $0.points.count > longOutline) }) else { return shape.path }
        let out = CGMutablePath()
        for part in parts {
            guard part.closed, redraw || part.points.count > longOutline else { add(part, to: out); continue }
            let line = flatten(part)
            guard line.count >= 3 else { continue }
            smooth(resample(line, to: redraw ? cutOutline : longOutline), into: out)
        }
        return out
    }

    private static func add(_ part: LottieWriter.Subpath, to path: CGMutablePath) {
        guard let first = part.points.first else { return }
        path.move(to: first)
        let n = part.points.count
        for i in 1..<(part.closed ? n + 1 : n) {
            let a = part.points[(i - 1) % n], b = part.points[i % n]
            let c1 = CGPoint(x: a.x + part.outs[(i - 1) % n].x, y: a.y + part.outs[(i - 1) % n].y)
            let c2 = CGPoint(x: b.x + part.ins[i % n].x, y: b.y + part.ins[i % n].y)
            path.addCurve(to: b, control1: c1, control2: c2)
        }
        if part.closed { path.closeSubpath() }
    }

    /// A closed subpath as a fine polyline (curves cut into short lines).
    static func flatten(_ part: LottieWriter.Subpath) -> [CGPoint] {
        let n = part.points.count
        var line: [CGPoint] = []
        for i in 0..<n {
            let a = part.points[i], b = part.points[(i + 1) % n]
            let c1 = CGPoint(x: a.x + part.outs[i].x, y: a.y + part.outs[i].y)
            let c2 = CGPoint(x: b.x + part.ins[(i + 1) % n].x, y: b.y + part.ins[(i + 1) % n].y)
            let straight = part.outs[i] == .zero && part.ins[(i + 1) % n] == .zero
            let steps = straight ? 1 : 8
            for s in 0..<steps {
                let t = Double(s) / Double(steps), u = 1 - t
                line.append(CGPoint(x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                                    y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y))
            }
        }
        return line
    }

    /// `count` points evenly spaced along the closed polyline, starting from its topmost point so the same
    /// outline starts at the same place in every frame.
    static func resample(_ line: [CGPoint], to count: Int) -> [CGPoint] {
        let start = line.indices.min { line[$0].y < line[$1].y } ?? 0
        let ring = Array(line[start...] + line[..<start]) + [line[start]]
        var lengths = [0.0]
        for i in 1..<ring.count { lengths.append(lengths[i - 1] + hypot(ring[i].x - ring[i - 1].x, ring[i].y - ring[i - 1].y)) }
        let total = lengths.last ?? 0
        guard total > 0 else { return Array(repeating: ring[0], count: count) }
        var out: [CGPoint] = []
        var j = 1
        for k in 0..<count {
            let d = total * Double(k) / Double(count)
            while j < ring.count - 1, lengths[j] < d { j += 1 }
            let span = max(lengths[j] - lengths[j - 1], 1e-9), t = (d - lengths[j - 1]) / span
            out.append(CGPoint(x: ring[j - 1].x + (ring[j].x - ring[j - 1].x) * t, y: ring[j - 1].y + (ring[j].y - ring[j - 1].y) * t))
        }
        return out
    }

    /// A closed curve through the points (Catmull-Rom, as cubic curves).
    private static func smooth(_ p: [CGPoint], into path: CGMutablePath) {
        let n = p.count
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
    }
}
