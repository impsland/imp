import CoreGraphics
import Foundation

/// Writes recorded frames as a Lottie document that a `.tgs` sticker may hold: shape layers with paths,
/// fills and gradient fills only (no pictures, no expressions, no masks, mattes, effects, text or
/// repeaters), 512×512 at 60 frames a second.
///
/// Consecutive frames whose shapes have the same make-up (the same paints and the same number of points in
/// every path) become one layer whose paths and paints are keyframed, every `stride` frames, and played
/// back in between by straight interpolation. A frame that differs from the ones around it is a layer of
/// its own.
struct LottieWriter {
    /// Sample every `stride`th frame of a run as a keyframe.
    var stride = 1
    /// Decimals kept for coordinates.
    var decimals = 1

    static let size = 512
    static let fps = 60

    func document(frames shapes: [[VectorShape]], name: String) -> Data {
        let frames = StickerShapes.items(shapes)
        // Each part (an eye, a horn, a note) is followed on its own, so one part coming and going leaves the
        // others alone. A part's layers are the stretches of frames in which it is drawn, the same way.
        var order: [String] = []
        var parts: [String: [(frame: Int, item: StickerShapes.Item)]] = [:]
        for (f, items) in frames.enumerated() {
            var before: String?
            for item in items {
                if parts[item.track] == nil {
                    // A new part goes right after the one drawn before it in this frame, so the stacking holds.
                    let at = before.flatMap { b in order.firstIndex(of: b).map { $0 + 1 } } ?? 0
                    order.insert(item.track, at: at)
                }
                parts[item.track, default: []].append((f, item))
                before = item.track
            }
        }
        var layers: [String] = []
        // Lottie lists the front layer first.
        for track in order.reversed() {
            let seen = parts[track] ?? []
            var start = 0
            while start < seen.count {
                var end = start
                let key = Self.makeUp(seen[start].item)
                while end + 1 < seen.count, seen[end + 1].frame == seen[end].frame + 1, Self.makeUp(seen[end + 1].item) == key { end += 1 }
                layers.append(layer(Array(seen[start...end]), index: layers.count + 1))
                start = end + 1
            }
        }
        let json = "{\"tgs\":1,\"v\":\"5.5.2\",\"fr\":\(Self.fps),\"ip\":0,\"op\":\(max(1, frames.count)),\"w\":\(Self.size),\"h\":\(Self.size),"
            + "\"nm\":\(Self.string(name)),\"ddd\":0,\"assets\":[],\"layers\":[\(layers.joined(separator: ","))]}"
        return Data(json.utf8)
    }

    // MARK: Make-up

    /// What must stay the same for two frames to be one layer: per shape, the paint's kind and stops and
    /// the point count of every subpath.
    private static func makeUp(_ item: StickerShapes.Item) -> String {
        let paints = item.paints.map { s -> String in
            switch s.paint {
            case .color: s.stroke == nil ? "c" : "s"
            case .linear(let stops, _, _): "l\(stops.count)"
            case .radial(let stops, _, _): "r\(stops.count)"
            }
        }.joined()
        return paints + ":" + subpaths(item.path).map { "\($0.points.count)\($0.closed ? "c" : "o")" }.joined(separator: ",")
    }

    // MARK: Layers

    /// One part over consecutive frames of the same make-up.
    private func layer(_ run: [(frame: Int, item: StickerShapes.Item)], index: Int) -> String {
        let a = run[0].frame, b = run[run.count - 1].frame
        var keys = Array(Swift.stride(from: 0, to: run.count, by: max(1, stride)))
        if keys.last != run.count - 1 { keys.append(run.count - 1) }
        let group = group(keys.map { run[$0] })
        return "{\"ddd\":0,\"ind\":\(index),\"ty\":4,\"sr\":1,\"ks\":\(Self.identity),\"ao\":0,"
            + "\"shapes\":[\(group)],\"ip\":\(a),\"op\":\(b + 1),\"st\":0,\"bm\":0}"
    }

    private static let identity = "{\"o\":{\"a\":0,\"k\":100},\"r\":{\"a\":0,\"k\":0},\"p\":{\"a\":0,\"k\":[0,0,0]},\"a\":{\"a\":0,\"k\":[0,0,0]},\"s\":{\"a\":0,\"k\":[100,100,100]}}"
    private static let groupTransform = "{\"ty\":\"tr\",\"p\":{\"a\":0,\"k\":[0,0]},\"a\":{\"a\":0,\"k\":[0,0]},\"s\":{\"a\":0,\"k\":[100,100]},\"r\":{\"a\":0,\"k\":0},\"o\":{\"a\":0,\"k\":100},\"sk\":{\"a\":0,\"k\":0},\"sa\":{\"a\":0,\"k\":0}}"

    /// One path over its keyframes: its subpaths, then its paints, the front one first.
    private func group(_ keys: [(frame: Int, item: StickerShapes.Item)]) -> String {
        let paths = keys.map { Self.subpaths($0.item.path) }
        var items: [String] = []
        for i in paths[0].indices {
            let values = paths.map { pathValue($0[i]) }
            items.append("{\"ty\":\"sh\",\"ks\":\(property(values, keys.map(\.frame), tolerance: 1.25, wrap: true))}")
        }
        for p in keys[0].item.paints.indices.reversed() {
            items.append(paint(keys.map { (frame: $0.frame, shape: $0.item.paints[p]) }))
        }
        items.append(Self.groupTransform)
        return "{\"ty\":\"gr\",\"it\":[\(items.joined(separator: ","))]}"
    }

    private func paint(_ keys: [(frame: Int, shape: VectorShape)]) -> String {
        let frames = keys.map(\.frame)
        switch keys[0].shape.paint {
        case .color where keys[0].shape.stroke != nil:
            let colors = keys.map { k -> String in
                guard case .color(let c) = k.shape.paint else { return "[0,0,0,1]" }
                return "[\(n(c.r, 3)),\(n(c.g, 3)),\(n(c.b, 3)),1]"
            }
            let opacity = keys.map { k -> String in
                guard case .color(let c) = k.shape.paint else { return "100" }
                return n(c.a * k.shape.opacity * 100, 1)
            }
            let widths = keys.map { n($0.shape.stroke ?? 1, 2) }
            return "{\"ty\":\"st\",\"c\":\(property(colors, frames, tolerance: 0.01)),\"o\":\(property(opacity, frames, tolerance: 1)),\"w\":\(property(widths, frames, tolerance: 0.25)),\"lc\":2,\"lj\":2,\"ml\":4}"
        case .color:
            let colors = keys.map { k -> String in
                guard case .color(let c) = k.shape.paint else { return "[0,0,0,1]" }
                return "[\(n(c.r, 3)),\(n(c.g, 3)),\(n(c.b, 3)),1]"
            }
            let opacity = keys.map { k -> String in
                guard case .color(let c) = k.shape.paint else { return "100" }
                return n(c.a * k.shape.opacity * 100, 1)
            }
            return "{\"ty\":\"fl\",\"c\":\(property(colors, frames, tolerance: 0.01)),\"o\":\(property(opacity, frames, tolerance: 1)),\"r\":1}"
        case .linear, .radial:
            var kind = 1, stopCount = 0
            var starts: [String] = [], ends: [String] = [], stops: [String] = []
            for k in keys {
                switch k.shape.paint {
                case .linear(let s, let a, let b):
                    kind = 1; stopCount = s.count
                    starts.append(point(a)); ends.append(point(b)); stops.append(gradient(s))
                case .radial(let s, let c, let r):
                    kind = 2; stopCount = s.count
                    starts.append(point(c)); ends.append(point(CGPoint(x: c.x + r, y: c.y))); stops.append(gradient(s))
                case .color: break
                }
            }
            let opacity = keys.map { n($0.shape.opacity * 100, 1) }
            return "{\"ty\":\"gf\",\"o\":\(property(opacity, frames, tolerance: 1)),\"r\":1,\"s\":\(property(starts, frames, tolerance: 0.75)),\"e\":\(property(ends, frames, tolerance: 0.75)),"
                + "\"t\":\(kind),\"g\":{\"p\":\(stopCount),\"k\":\(property(stops, frames, tolerance: 0.01))},\"h\":{\"a\":0,\"k\":0},\"a\":{\"a\":0,\"k\":0}}"
        }
    }

    private func gradient(_ stops: [VectorPaint.Stop]) -> String {
        let colours = stops.flatMap { [n($0.at, 3), n($0.color.r, 3), n($0.color.g, 3), n($0.color.b, 3)] }
        let alphas = stops.flatMap { [n($0.at, 3), n($0.color.a, 3)] }
        return "[" + (colours + alphas).joined(separator: ",") + "]"
    }

    /// A value that is the same in every keyframe is written once. One that changes is keyframed and moves in
    /// a straight line between keyframes. A keyframe that a straight line between its neighbours already
    /// passes within `tolerance` of (in every number of the value) is left out. `wrap`: a path's value sits in
    /// a one-item array in a keyframe.
    private func property(_ values: [String], _ frames: [Int], tolerance: Double, wrap: Bool = false) -> String {
        if values.allSatisfy({ $0 == values[0] }) { return "{\"a\":0,\"k\":\(values[0])}" }
        let kept = Self.reduce(values.map(Self.numbers), frames, tolerance: tolerance)
        if kept.count == 1 { return "{\"a\":0,\"k\":\(values[kept[0]])}" }
        var keys: [String] = []
        for (j, i) in kept.enumerated() {
            // A keyframe's value is always an array: a path in one, a number as one.
            let s = wrap || !values[i].hasPrefix("[") ? "[\(values[i])]" : values[i]
            if j == kept.count - 1 {
                keys.append("{\"t\":\(frames[i]),\"s\":\(s)}")
            } else {
                keys.append("{\"t\":\(frames[i]),\"s\":\(s),\"i\":{\"x\":[1],\"y\":[1]},\"o\":{\"x\":[0],\"y\":[0]}}")
            }
        }
        return "{\"a\":1,\"k\":[\(keys.joined(separator: ","))]}"
    }

    /// The numbers in a written value, in order.
    static func numbers(_ text: String) -> [Double] {
        var out: [Double] = [], current = ""
        for ch in text {
            if ch.isNumber || ch == "." || (ch == "-" && current.isEmpty) { current.append(ch) } else if !current.isEmpty {
                out.append(Double(current) ?? 0); current = ""
            }
        }
        if !current.isEmpty { out.append(Double(current) ?? 0) }
        return out
    }

    /// The keyframes to keep: the first, the last, and each one the line from the last kept one can't reach
    /// within `tolerance`.
    static func reduce(_ values: [[Double]], _ frames: [Int], tolerance: Double) -> [Int] {
        guard values.count > 2 else { return Array(values.indices) }
        var kept = [0]
        var anchor = 0
        var j = 2
        while j < values.count {
            // Can the line from `anchor` to `j` stand in for every keyframe between them?
            let fits = (anchor + 1..<j).allSatisfy { i in
                let t = Double(frames[i] - frames[anchor]) / Double(max(1, frames[j] - frames[anchor]))
                return zip(values[i].indices, values[i]).allSatisfy { k, v in
                    guard k < values[anchor].count, k < values[j].count else { return false }
                    return abs(values[anchor][k] + (values[j][k] - values[anchor][k]) * t - v) <= tolerance
                }
            }
            if !fits {
                anchor = j - 1
                kept.append(anchor)
            }
            j += 1
        }
        kept.append(values.count - 1)
        return kept
    }

    // MARK: Paths

    struct Subpath {
        var points: [CGPoint] = []
        /// Handles relative to their point, as Lottie wants them.
        var ins: [CGPoint] = []
        var outs: [CGPoint] = []
        var closed = false
    }

    /// A path's subpaths as points with in and out handles. Quadratic curves become cubic. A closing point
    /// on top of the first one is merged into it.
    static func subpaths(_ path: CGPath) -> [Subpath] {
        var result: [Subpath] = []
        var current = Subpath()
        func finish() {
            if current.closed, current.points.count > 1, let first = current.points.first, let last = current.points.last,
               hypot(first.x - last.x, first.y - last.y) < 0.001 {
                current.ins[0] = current.ins.removeLast()
                current.points.removeLast()
                current.outs.removeLast()
            }
            if !current.points.isEmpty { result.append(current) }
            current = Subpath()
        }
        func add(_ p: CGPoint, in handle: CGPoint) {
            current.points.append(p); current.ins.append(CGPoint(x: handle.x - p.x, y: handle.y - p.y)); current.outs.append(.zero)
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                finish()
                add(e.points[0], in: e.points[0])
            case .addLineToPoint:
                add(e.points[0], in: e.points[0])
            case .addQuadCurveToPoint:
                guard let last = current.points.last else { return }
                let c = e.points[0], p = e.points[1]
                let c1 = CGPoint(x: last.x + 2 / 3 * (c.x - last.x), y: last.y + 2 / 3 * (c.y - last.y))
                let c2 = CGPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
                current.outs[current.outs.count - 1] = CGPoint(x: c1.x - last.x, y: c1.y - last.y)
                add(p, in: c2)
            case .addCurveToPoint:
                guard let last = current.points.last else { return }
                current.outs[current.outs.count - 1] = CGPoint(x: e.points[0].x - last.x, y: e.points[0].y - last.y)
                add(e.points[2], in: e.points[1])
            case .closeSubpath:
                current.closed = true
                finish()
            @unknown default: break
            }
        }
        finish()
        return result
    }

    private func pathValue(_ s: Subpath) -> String {
        func list(_ points: [CGPoint]) -> String { "[" + points.map(point).joined(separator: ",") + "]" }
        return "{\"c\":\(s.closed),\"v\":\(list(s.points)),\"i\":\(list(s.ins)),\"o\":\(list(s.outs))}"
    }

    private func point(_ p: CGPoint) -> String { "[\(n(p.x, decimals)),\(n(p.y, decimals))]" }

    /// A number with at most `places` decimals and nothing it does not need.
    private func n(_ x: Double, _ places: Int) -> String {
        guard x.isFinite else { return "0" }
        let k = pow(10, Double(places))
        let r = (x * k).rounded() / k
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.\(places)f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func string(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
