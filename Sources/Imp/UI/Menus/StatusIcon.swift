import AppKit
import SwiftUI

/// The menu bar template icon, built from the same head and horn geometry as the live Imp
/// (horns a little larger so they read at 18 pt). A hairline gap separates each horn from the
/// dome so they read as horns rather than ears. The eyes are punched out.
@MainActor
enum StatusIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // The head fills the menu bar slot. Horn size is relative to the head, so it's scaled
            // back to keep the horns their original, small size.
            let head = Head(cx: 10, cy: 13.7, rx: 9.6, top: 7.6, bottom: 5.2,
                            square: 2.05, sag: 0, peak: 0, wobble: 0, lean: 0, t: 0)
            var face = Face()
            face.hornSize = 1.5 * 7.6 / head.rx
            face.horn = -4
            let pose = Pose(face)
            let horns = [-1.0, 1.0].map { Horn(side: $0, head: head, pose: pose, face: face, wiggle: 0).front.cgPath }

            // Centre the drawing on its actual ink (horns included), so it sits mid-bar.
            let ink = horns.reduce(head.path.cgPath.boundingBoxOfPath) { $0.union($1.boundingBoxOfPath) }
            cg.translateBy(x: 10 - ink.midX, y: 10 - ink.midY)

            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(head.path.cgPath)
            cg.fillPath()
            cg.setBlendMode(.clear)
            cg.setLineWidth(1.2)
            for h in horns { cg.addPath(h); cg.strokePath() }
            cg.setBlendMode(.normal)
            for h in horns { cg.addPath(h); cg.fillPath() }
            // Eyes: a startled look. The right eye pops wider than the left, as if Imp just
            // noticed something. Both sit on the same line just below the widest point.
            cg.setBlendMode(.clear)
            for (side, w, h) in [(-1.0, 2.6, 3.6), (1.0, 3.8, 5.3)] {
                let c = head.project(.onBall(lon: side * 0.45, lat: 0.1))
                cg.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - h / 2 - (h - 3.6) * 0.25, width: w, height: h))
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// A little colour dot for menus listing the Imps.
    static func swatch(hue: Double) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color.imp(hue)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
