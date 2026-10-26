import SwiftUI

/// Glows and shadows that fade out completely, with no visible rim.
///
/// A two-stop linear fade (colour → clear) has a kink where it reaches zero, and the eye reads that
/// kink as an edge. Filling it into a shape smaller than the gradient cuts it off outright. These
/// follow (1 − t²)², which arrives at zero flat, and always fill exactly the gradient's own circle.
enum SoftLight {
    static func falloff(_ color: Color, _ opacity: Double, stops n: Int = 12) -> Gradient {
        Gradient(stops: (0...n).map { i in
            let t = Double(i) / Double(n), k = 1 - t * t
            return .init(color: color.opacity(opacity * k * k), location: t)
        })
    }

    /// A round glow fully faded at `radius`. `squash` flattens it vertically (a shadow on the floor).
    static func glow(_ ctx: inout GraphicsContext, at center: CGPoint, radius r: CGFloat, color: Color, opacity: Double,
                     squash: CGFloat = 1) {
        guard r > 0, opacity > 0 else { return }
        var g = ctx
        g.translateBy(x: center.x, y: center.y)
        g.scaleBy(x: 1, y: squash)
        g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
               with: .radialGradient(falloff(color, opacity), center: .zero, startRadius: 0, endRadius: r))
    }
}

/// A glow as a view, for layouts (the pedestal under an Imp). Draws past its frame by nothing:
/// give it the full size the light should reach.
struct SoftGlow: View {
    var color: Color
    var opacity: Double

    var body: some View {
        Canvas { ctx, size in
            SoftLight.glow(&ctx, at: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.width / 2,
                           color: color, opacity: opacity, squash: size.height / max(1, size.width))
        }
        .allowsHitTesting(false)
    }
}
