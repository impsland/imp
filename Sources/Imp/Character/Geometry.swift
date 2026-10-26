import SwiftUI

struct Vec3 {
    var x, y, z: Double
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vec3, k: Double) -> Vec3 { Vec3(x: a.x * k, y: a.y * k, z: a.z * k) }
    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vec3) -> Vec3 { Vec3(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x) }
    var normalized: Vec3 { self * (1 / max(1e-9, dot(self).squareRoot())) }

    /// Unit vector on the head ball: longitude right +, latitude down +.
    static func onBall(lon: Double, lat: Double) -> Vec3 {
        Vec3(x: cos(lat) * sin(lon), y: sin(lat), z: cos(lat) * cos(lon))
    }
}

/// Which way the face is turned. The silhouette stays a soft 2D blob, but the face (eyes,
/// blush, horns) lives on an imaginary ball inside it and turns with yaw/pitch.
struct Pose {
    let yaw: Double, pitch: Double

    init(_ f: Face) {
        yaw = f.lookX * 0.72
        pitch = f.lookY * 0.62
    }

    func rotate(_ v: Vec3) -> Vec3 {
        // Yaw: turning right moves the front to the right.
        let a = Vec3(x: v.x * cos(yaw) + v.z * sin(yaw), y: v.y, z: -v.x * sin(yaw) + v.z * cos(yaw))
        // Pitch: looking down brings the top toward the viewer.
        return Vec3(x: a.x, y: a.y * cos(pitch) + a.z * sin(pitch), z: -a.y * sin(pitch) + a.z * cos(pitch))
    }
}

/// Imp's mochi head: a round dome over a softly flattened base, in a 100×100 design space.
/// `cy` is the equator (the widest line). The dome rises `top` above it, the base sits `bottom` below.
struct Head {
    var cx: Double, cy: Double
    var rx: Double, top: Double, bottom: Double
    var square: Double, sag: Double, peak: Double, wobble: Double, lean: Double, t: Double
    private(set) var path = Path()

    init(cx: Double, cy: Double, rx: Double, top: Double, bottom: Double,
         square: Double, sag: Double, peak: Double, wobble: Double, lean: Double, t: Double) {
        self.cx = cx; self.cy = cy; self.rx = rx; self.top = top; self.bottom = bottom
        self.square = square; self.sag = sag; self.peak = peak; self.wobble = wobble; self.lean = lean; self.t = t
        var p = Path()
        let n = 96
        for i in 0..<n {
            let pt = point(-Double.pi / 2 + Double(i) / Double(n) * 2 * .pi)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        path = p
    }

    /// Outline point at θ (−π/2 = top, 0 = right, π/2 = bottom).
    func point(_ theta: Double) -> CGPoint {
        let c = cos(theta), s = sin(theta)
        // The base flattens gradually from the equator down, so the outline has no kinks.
        let k = pow(max(0, s), 1.5)
        let ex = 2 / (square + 0.25 * k), ey = 2 / (square + 1.6 * k)
        var x = rx * copysign(pow(abs(c), ex), c)
        var y = (s < 0 ? top : bottom) * copysign(pow(abs(s), ey), s)
        // Melting cheeks bulge out just above the base.
        if s > 0 { x *= 1 + sag * 0.08 * exp(-pow((y / bottom - 0.45) / 0.35, 2)) }
        // Startled tuft at the very top.
        let d = remainder(theta + .pi / 2, 2 * .pi)
        y -= peak * top * 0.12 * exp(-d * d / 0.08)
        let w = ripple(theta)
        return CGPoint(x: cx + x * w + shear(y), y: cy + y * w)
    }

    /// Jelly wobble: a radial scale that varies around the outline.
    private func ripple(_ theta: Double) -> Double {
        1 + wobble * (0.03 * sin(3 * theta + t * 4.2) + 0.018 * sin(5 * theta - t * 6.1))
    }

    /// Turning leans the dome a little toward where Imp looks.
    private func shear(_ y: Double) -> Double { lean * 1.8 * max(0, -y / top) }

    /// Screen position of a (rotated) point on the face ball, consistent with the silhouette.
    /// Wobbles with the outline, so features (and horn roots) stay seated on the skin.
    func project(_ v: Vec3) -> CGPoint {
        let x = rx * v.x, y = v.y * (v.y < 0 ? top : bottom)
        let w = wobble == 0 ? 1 : ripple(atan2(v.y, v.x))
        return CGPoint(x: cx + x * w + shear(y), y: cy + y * w)
    }
}
