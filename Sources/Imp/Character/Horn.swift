import SwiftUI

/// One of Imp's horns: small, stubby and cute, like a child's. It's a real 3D object: a tube
/// swept along a short spine that rises from the head's shoulder, thick at the base and
/// curling outward at the tip. Each cross-section is a 3D circle turned with the head and
/// projected, so the horn foreshortens, slides and hides exactly like part of the head.
struct Horn {
    /// Slices outside the head and facing the viewer: drawn over the head.
    let front: Path
    /// Slices behind the dome or still inside the skin: drawn first, so the head covers them.
    let back: Path
    /// How much the root faces the viewer (0…1), for the contact shadow.
    let facing: Double
    let base: CGPoint
    let baseR: Double
    let light: CGPoint

    static let rings = 14
    static let segments = 16
    /// How far the base continues under the skin (fraction of the horn's length). Because the horn
    /// really grows out of the head, it stays attached along its whole base at every angle,
    /// including edge-on at the rim, instead of touching the outline at a single point.
    static let embed = 0.5

    init(side: Double, head: Head, pose: Pose, face f: Face, wiggle: Double) {
        // Rooted on the shoulder of the dome, set well out to the side.
        let root = Vec3.onBall(lon: side * 0.9, lat: -0.6)
        // Lean out along the surface normal, then curl back up toward the middle at the tip.
        var axis = (root * 0.62 + Vec3(x: 0, y: -1, z: 0) * 0.38).normalized
        let sideways = Vec3(x: side, y: 0, z: 0)
        var out = (sideways - axis * sideways.dot(axis)).normalized
        // Positive lean tips the horn outward (droopy). Perky horns lean in.
        let lean = (-f.horn + wiggle) * .pi / 180
        (axis, out) = (axis * cos(lean) + out * sin(lean), out * cos(lean) - axis * sin(lean))

        let s = f.hornSize
        let length = 0.23 * s, curl = -0.085 * s, rBase = 0.145 * s, rTip = 0.042 * s
        let rootR = pose.rotate(root)
        let origin = head.project(rootR)
        let scale = head.rx
        func screen(_ p: Vec3) -> CGPoint {
            let r = pose.rotate(p) - rootR
            return CGPoint(x: origin.x + r.x * scale, y: origin.y + r.y * scale)
        }
        // t < 0 is the part under the skin: straight, full width.
        func spine(_ t: Double) -> Vec3 { root + axis * (length * t) + out * (curl * pow(max(0, t), 2.6)) }
        func tangent(_ t: Double) -> Vec3 { (axis * length + out * (curl * 2.6 * pow(max(0, t), 1.6))).normalized }
        // Plump, gumdrop-like body (convex sides) tapering to a soft, rounded point.
        func radius(_ t: Double) -> Double {
            let k = max(0, t)
            return rTip + (rBase - rTip) * (1 - pow(k, 1.4)) * (1 - 0.25 * k)
        }

        let ts = [-Self.embed] + (0...Self.rings).map { 1 - pow(1 - Double($0) / Double(Self.rings), 1.3) }
        let rings = ts.map { t -> [CGPoint] in
            let c = spine(t), tan = tangent(t)
            let u = (out - tan * out.dot(tan)).normalized, w = tan.cross(u)
            return (0..<Self.segments).map { k in
                let phi = Double(k) / Double(Self.segments) * 2 * .pi
                return screen(c + (u * cos(phi) + w * sin(phi)) * radius(t))
            }
        }
        // Each slice goes in front only if it's outside the head and on the visible side.
        func isFront(_ t: Double) -> Bool {
            let p = spine(t)
            return p.dot(p) > 1 && pose.rotate(p).z > 0
        }
        var front = Path(), back = Path()
        func add(_ points: [CGPoint], at t: Double) {
            if isFront(t) { Self.addConvexHull(points, to: &front) } else { Self.addConvexHull(points, to: &back) }
        }
        for i in 0..<(ts.count - 1) { add(rings[i] + rings[i + 1], at: (ts[i] + ts[i + 1]) / 2) }
        // Rounded tip: a sphere projects to a circle.
        let tip = screen(spine(1)), tr = rTip * scale
        add((0..<Self.segments).map { k in
            let phi = Double(k) / Double(Self.segments) * 2 * .pi
            return CGPoint(x: tip.x + tr * cos(phi), y: tip.y + tr * sin(phi))
        }, at: 1)

        self.front = front
        self.back = back
        facing = max(0, min(1, rootR.z * 4))
        base = origin
        baseR = rBase * scale
        let mid = screen(spine(0.4))
        light = CGPoint(x: mid.x - baseR * 0.35, y: mid.y - baseR * 0.3)
    }

    /// Monotone-chain hull, always added with the same winding so the union fills solidly.
    private static func addConvexHull(_ points: [CGPoint], to path: inout Path) {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func chain(_ pts: [CGPoint]) -> [CGPoint] {
            var h: [CGPoint] = []
            for pt in pts {
                while h.count >= 2, cross(h[h.count - 2], h[h.count - 1], pt) <= 0 { h.removeLast() }
                h.append(pt)
            }
            return h.dropLast()
        }
        let hull = chain(p) + chain(p.reversed())
        path.addLines(hull)
        path.closeSubpath()
    }

    /// Draws this layer of the horn: `front` after the head, the rest before it.
    func draw(in ctx: inout GraphicsContext, head: Head, front layer: Bool, palette: Palette) {
        let shape = layer ? front : back
        guard !shape.isEmpty else { return }
        if layer && facing > 0.01 {
            // Soft contact shadow where the horn sits on the skin.
            var shadow = ctx
            shadow.clip(to: head.path)
            shadow.opacity = facing
            let r = baseR * 1.7
            shadow.fill(Path(ellipseIn: CGRect(x: base.x - r, y: base.y - r * 0.55, width: 2 * r, height: 2 * r)),
                        with: .radialGradient(Gradient(colors: [Color(red: 0.4, green: 0.03, blue: 0.05).opacity(0.18), .clear]),
                                              center: CGPoint(x: base.x, y: base.y + r * 0.45), startRadius: 0, endRadius: r))
        }
        ctx.fill(shape, with: .radialGradient(Gradient(colors: [palette.hornLight, palette.hornDark]),
                                              center: light, startRadius: 0, endRadius: baseR * 1.7))
    }
}
