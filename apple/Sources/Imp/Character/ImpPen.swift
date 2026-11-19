import SwiftUI

/// A paint that can be read back. The screen's `GraphicsContext.Shading` is opaque, so the drawing names
/// its paints here and each pen turns them into its own.
enum PenPaint {
    case color(Color)
    case linear(Gradient, start: CGPoint, end: CGPoint)
    /// A radial gradient from the centre (radius 0) out to `radius`.
    case radial(Gradient, center: CGPoint, radius: CGFloat)

    var shading: GraphicsContext.Shading {
        switch self {
        case .color(let c): .color(c)
        case .linear(let g, let a, let b): .linearGradient(g, startPoint: a, endPoint: b)
        case .radial(let g, let c, let r): .radialGradient(g, center: c, startRadius: 0, endRadius: r)
        }
    }
}

/// A small mark drawn by name: an SF Symbol filling its box, or a letter centred in it.
enum PenMark: Equatable {
    case symbol(String)
    case letter(String, size: CGFloat)
}

/// What Imp's drawing needs from where it draws. `GraphicsContext` draws it on screen. `VectorPen`
/// records it as vector shapes (the sticker export). Each copy of a pen carries its own transform,
/// opacity and clip, as `GraphicsContext` does.
protocol ImpPen {
    var penOpacity: Double { get set }
    /// Names what is drawn next (an eye, a horn), so a recording pen can follow the same part from frame
    /// to frame. The screen ignores it.
    var penTag: String { get set }
    mutating func penTranslate(_ x: CGFloat, _ y: CGFloat)
    mutating func penScale(_ x: CGFloat, _ y: CGFloat)
    mutating func penRotate(_ radians: Double)
    mutating func penConcat(_ transform: CGAffineTransform)
    mutating func penClip(_ path: Path)
    /// `site`: where in the drawing code the call is, so the same call is known again in the next frame.
    func penFill(_ path: Path, _ paint: PenPaint, at site: PenSite)
    func penStroke(_ path: Path, _ color: Color, _ style: StrokeStyle, at site: PenSite)
    func penMark(_ mark: PenMark, _ color: Color, in rect: CGRect, at site: PenSite)
}

/// A place in the drawing code (costs nothing to make: two constants).
struct PenSite: Hashable {
    let file: StaticString
    let line: UInt
    static func == (a: Self, b: Self) -> Bool { a.line == b.line && a.file.description == b.file.description }
    func hash(into h: inout Hasher) { h.combine(line); h.combine(file.description) }
    var name: String { "\(file):\(line)" }
}

extension ImpPen {
    func penFill(_ path: Path, _ paint: PenPaint, file: StaticString = #fileID, line: UInt = #line) {
        penFill(path, paint, at: PenSite(file: file, line: line))
    }
    func penStroke(_ path: Path, _ color: Color, _ style: StrokeStyle, file: StaticString = #fileID, line: UInt = #line) {
        penStroke(path, color, style, at: PenSite(file: file, line: line))
    }
    func penMark(_ mark: PenMark, _ color: Color, in rect: CGRect, file: StaticString = #fileID, line: UInt = #line) {
        penMark(mark, color, in: rect, at: PenSite(file: file, line: line))
    }
}

extension GraphicsContext: ImpPen {
    var penOpacity: Double {
        get { opacity }
        set { opacity = newValue }
    }
    var penTag: String {
        get { "" }
        set {}
    }
    mutating func penTranslate(_ x: CGFloat, _ y: CGFloat) { translateBy(x: x, y: y) }
    mutating func penScale(_ x: CGFloat, _ y: CGFloat) { scaleBy(x: x, y: y) }
    mutating func penRotate(_ radians: Double) { rotate(by: .radians(radians)) }
    mutating func penConcat(_ transform: CGAffineTransform) { concatenate(transform) }
    mutating func penClip(_ path: Path) { clip(to: path) }
    func penFill(_ path: Path, _ paint: PenPaint, at site: PenSite) { fill(path, with: paint.shading) }
    func penStroke(_ path: Path, _ color: Color, _ style: StrokeStyle, at site: PenSite) { stroke(path, with: .color(color), style: style) }

    func penMark(_ mark: PenMark, _ color: Color, in rect: CGRect, at site: PenSite) {
        switch mark {
        case .symbol(let name):
            var image = resolve(Image(systemName: name))
            image.shading = .color(color)
            draw(image, in: rect)
        case .letter(let text, let size):
            draw(Text(verbatim: text).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(color),
                 at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }
}
