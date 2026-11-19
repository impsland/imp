import AppKit
import CoreText
import SwiftUI

/// A colour as four numbers from 0 to 1, in sRGB.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = color.resolve(in: EnvironmentValues()).cgColor
        let c = cg.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        if c.count >= 4 { self.init(r: c[0], g: c[1], b: c[2], a: c[3]) } else { self.init(r: c[0], g: c[0], b: c[0], a: c.last ?? 1) }
    }
}

/// A paint once it is placed on the canvas.
enum VectorPaint: Equatable {
    struct Stop: Equatable { var at: Double; var color: RGBA }
    case color(RGBA)
    case linear([Stop], start: CGPoint, end: CGPoint)
    case radial([Stop], center: CGPoint, radius: Double)
}

/// One shape on the canvas, in drawing order (the first is at the back): filled, or stroked along its
/// path (`stroke`: the line's width, with round ends).
struct VectorShape {
    var path: CGPath
    var paint: VectorPaint
    var opacity: Double
    var stroke: Double?
    /// The part this is, from one frame to the next: its tag and the drawing call that made it.
    var track = ""
    /// Cut by a clip, so its points come and go from frame to frame (`StickerShapes` evens them out).
    var clipped = false
}

/// Where a `VectorPen` writes what it draws.
final class VectorLog {
    var shapes: [VectorShape] = []
}

/// A pen that records Imp's drawing as filled vector shapes on the canvas instead of drawing pixels, for
/// stickers. Transforms are applied to the points, a clip is cut out of the shape (only when the shape
/// pokes out of it), a stroke becomes the outline it covers, and a mark (an SF Symbol, a letter) becomes
/// a path of its own, since a sticker may hold no pictures.
struct VectorPen: ImpPen {
    let log: VectorLog
    private var transform = CGAffineTransform.identity
    private var clip: CGPath?
    var penOpacity: Double = 1
    var penTag = ""

    init(log: VectorLog) { self.log = log }

    mutating func penTranslate(_ x: CGFloat, _ y: CGFloat) { transform = transform.translatedBy(x: x, y: y) }
    mutating func penScale(_ x: CGFloat, _ y: CGFloat) { transform = transform.scaledBy(x: x, y: y) }
    mutating func penRotate(_ radians: Double) { transform = transform.rotated(by: radians) }
    mutating func penConcat(_ t: CGAffineTransform) { transform = t.concatenating(transform) }

    mutating func penClip(_ path: Path) {
        let placed = placed(path.cgPath)
        clip = clip.map { $0.intersection(placed) } ?? placed
    }

    /// A shape is recorded even while it is see-through, so a fading shape keeps its place from frame to frame.
    func penFill(_ path: Path, _ paint: PenPaint, at site: PenSite) {
        var shape = placed(path.cgPath)
        var cut = false
        if let clip, clip != shape, !Self.inside(shape, clip) { shape = shape.intersection(clip); cut = true }
        guard !shape.isEmpty, !shape.boundingBoxOfPath.isEmpty else { return }
        log.shapes.append(VectorShape(path: shape, paint: placed(paint), opacity: penOpacity, track: penTag + "|" + site.name, clipped: cut))
    }

    /// A line stays a line (its few points, a width) while it is inside the clip. Only a line that pokes out
    /// of the clip becomes the outline it covers, cut by the clip.
    func penStroke(_ path: Path, _ color: Color, _ style: StrokeStyle, at site: PenSite) {
        let centre = placed(path.cgPath)
        if clip.map({ Self.inside(centre, $0) }) ?? true {
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            log.shapes.append(VectorShape(path: centre, paint: .color(RGBA(color)), opacity: penOpacity, stroke: style.lineWidth * scale,
                                          track: penTag + "|" + site.name))
            return
        }
        let outline = path.cgPath.copy(strokingWithWidth: style.lineWidth, lineCap: style.lineCap, lineJoin: style.lineJoin,
                                       miterLimit: style.miterLimit)
        penFill(Path(outline), .color(color), at: site)
    }

    func penMark(_ mark: PenMark, _ color: Color, in rect: CGRect, at site: PenSite) {
        guard let path = Self.path(of: mark, in: rect) else { return }
        // A different mark is a different part (a note, then a heart).
        var named = self
        switch mark {
        case .symbol(let name): named.penTag = penTag + "-" + name
        case .letter(let text, _): named.penTag = penTag + "-" + text
        }
        named.penFill(Path(path), .color(color), at: site)
    }

    // MARK: Placing

    private func placed(_ path: CGPath) -> CGPath {
        var t = transform
        return path.copy(using: &t) ?? path
    }

    private func placed(_ paint: PenPaint) -> VectorPaint {
        func stops(_ g: Gradient) -> [VectorPaint.Stop] { Self.fewer(g.stops.map { .init(at: $0.location, color: RGBA($0.color)) }) }
        switch paint {
        case .color(let c): return .color(RGBA(c))
        case .linear(let g, let a, let b): return .linear(stops(g), start: a.applying(transform), end: b.applying(transform))
        case .radial(let g, let c, let r):
            // A sticker's radial gradient is round: a squashed one keeps the wider of its two radii.
            let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
            return .radial(stops(g), center: c.applying(transform), radius: r * scale)
        }
    }

    /// A sticker keeps a gradient to a few stops: a long one (a soft glow's falloff) is sampled at four.
    static let maxStops = 4

    static func fewer(_ stops: [VectorPaint.Stop]) -> [VectorPaint.Stop] {
        guard stops.count > maxStops, let first = stops.first, let last = stops.last else { return stops }
        return (0..<maxStops).map { k in
            let at = first.at + (last.at - first.at) * Double(k) / Double(maxStops - 1)
            let j = stops.firstIndex { $0.at >= at } ?? stops.count - 1
            guard j > 0 else { return VectorPaint.Stop(at: at, color: stops[0].color) }
            let a = stops[j - 1], b = stops[j]
            let t = b.at > a.at ? (at - a.at) / (b.at - a.at) : 0
            func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            return VectorPaint.Stop(at: at, color: RGBA(r: mix(a.color.r, b.color.r), g: mix(a.color.g, b.color.g),
                                                        b: mix(a.color.b, b.color.b), a: mix(a.color.a, b.color.a)))
        }
    }

    /// Whether every point of `shape` (its corners and handles) is inside `clip`, so there is nothing to cut.
    private static func inside(_ shape: CGPath, _ clip: CGPath) -> Bool {
        var all = true
        shape.applyWithBlock { element in
            guard all else { return }
            let e = element.pointee
            let n: Int = switch e.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            for i in 0..<n where !clip.contains(e.points[i]) { all = false }
        }
        return all
    }

    // MARK: Marks

    /// A mark as a path filling `rect` (a symbol) or centred on it (a letter). Symbols that have a
    /// character are drawn from the rounded system font; the others are drawn here.
    static func path(of mark: PenMark, in rect: CGRect) -> CGPath? {
        switch mark {
        case .letter(let text, let size):
            return letter(text, size: size, centre: CGPoint(x: rect.midX, y: rect.midY))
        case .symbol(let name):
            let unit: CGPath? = switch name {
            case "music.note": letterUnit("♪")
            case "music.quarternote.3": letterUnit("♫")
            case "questionmark": letterUnit("?")
            case "exclamationmark": letterUnit("!")
            case "heart.fill": heart()
            case "sparkles": sparkles()
            case "lightbulb.fill": bulb()
            case "gearshape.fill": gear()
            case "drop.fill": drop()
            default: nil
            }
            guard let unit else { return nil }
            // The unit shapes fill a 1×1 box from −0.5 to 0.5.
            var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: rect.width, y: rect.height)
            return unit.copy(using: &t)
        }
    }

    private static func font(_ size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return rounded as CTFont
    }

    /// The glyphs of `text` at `size`, centred on `centre`, y down.
    private static func letter(_ text: String, size: CGFloat, centre: CGPoint) -> CGPath? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(size)]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (g, p) in zip(glyphs, positions) {
                if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
                    path.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: p.y))
                }
            }
        }
        let box = path.boundingBoxOfPath
        guard !box.isEmpty else { return nil }
        // Font space is y up: flip it and centre the ink on `centre`.
        var t = CGAffineTransform(translationX: centre.x, y: centre.y).scaledBy(x: 1, y: -1).translatedBy(x: -box.midX, y: -box.midY)
        return path.copy(using: &t)
    }

    /// A character fitted into the unit box.
    private static func letterUnit(_ text: String) -> CGPath? {
        guard let p = letter(text, size: 100, centre: .zero) else { return nil }
        let box = p.boundingBoxOfPath
        let k = 1 / max(box.width, box.height)
        var t = CGAffineTransform(scaleX: k, y: k)
        return p.copy(using: &t)
    }

    private static func heart() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0.42))
        p.addCurve(to: CGPoint(x: -0.5, y: -0.12), control1: CGPoint(x: -0.2, y: 0.25), control2: CGPoint(x: -0.5, y: 0.1))
        p.addArc(center: CGPoint(x: -0.25, y: -0.15), radius: 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
        p.addArc(center: CGPoint(x: 0.25, y: -0.15), radius: 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
        p.addCurve(to: CGPoint(x: 0, y: 0.42), control1: CGPoint(x: 0.5, y: 0.1), control2: CGPoint(x: 0.2, y: 0.25))
        p.closeSubpath()
        return p
    }

    private static func star(_ p: CGMutablePath, at c: CGPoint, r: Double) {
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        p.closeSubpath()
    }

    private static func sparkles() -> CGPath {
        let p = CGMutablePath()
        star(p, at: CGPoint(x: -0.08, y: 0.08), r: 0.42)
        star(p, at: CGPoint(x: 0.3, y: -0.3), r: 0.18)
        return p
    }

    private static func bulb() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -0.33, y: -0.5, width: 0.66, height: 0.66))
        p.addRoundedRect(in: CGRect(x: -0.17, y: 0.2, width: 0.34, height: 0.28), cornerWidth: 0.06, cornerHeight: 0.06)
        return p
    }

    private static func gear() -> CGPath {
        let p = CGMutablePath()
        let teeth = 8
        for i in 0..<(teeth * 2) {
            let a = Double(i) / Double(teeth * 2) * 2 * .pi
            let r = i % 2 == 0 ? 0.5 : 0.38
            let a0 = a - .pi / Double(teeth * 2) * 0.6, a1 = a + .pi / Double(teeth * 2) * 0.6
            let p0 = CGPoint(x: cos(a0) * r, y: sin(a0) * r), p1 = CGPoint(x: cos(a1) * r, y: sin(a1) * r)
            i == 0 ? p.move(to: p0) : p.addLine(to: p0)
            p.addLine(to: p1)
        }
        p.closeSubpath()
        return p
    }

    private static func drop() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -0.5))
        p.addCurve(to: CGPoint(x: 0, y: 0.5), control1: CGPoint(x: 0.15, y: -0.2), control2: CGPoint(x: 0.55, y: 0.5))
        p.addCurve(to: CGPoint(x: 0, y: -0.5), control1: CGPoint(x: -0.55, y: 0.5), control2: CGPoint(x: -0.15, y: -0.2))
        p.closeSubpath()
        return p
    }
}
