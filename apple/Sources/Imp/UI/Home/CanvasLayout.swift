import CoreGraphics

/// Where Imps stand on the home canvas. A place is the centre of an Imp as a fraction of the
/// canvas's width and height, so a place survives resizing the window.
enum CanvasLayout {
    /// Room kept below a figure for its name, and around the edges.
    static let nameRoom: CGFloat = 30
    static let margin: CGFloat = 8

    /// The centre of an Imp `figure` points square, in the canvas's points. It always stays whole
    /// inside the canvas, however small the window gets.
    static func point(of place: CGPoint, in size: CGSize, figure: CGFloat) -> CGPoint {
        CGPoint(x: clamp(place.x * size.width, figure / 2 + margin, size.width - figure / 2 - margin),
                y: clamp(place.y * size.height, figure / 2 + margin, size.height - figure / 2 - nameRoom - margin))
    }

    /// The place of a point the Imp was dragged to.
    static func place(at point: CGPoint, in size: CGSize, figure: CGFloat) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let kept = self.point(of: CGPoint(x: point.x / size.width, y: point.y / size.height), in: size, figure: figure)
        return CGPoint(x: kept.x / size.width, y: kept.y / size.height)
    }

    // MARK: Canvas and screen
    //
    // The canvas runs top-down from its top-left corner; the screen runs bottom-up. `canvas` is the
    // canvas's rectangle on screen (points, the same unit on both sides, so the backing scale does not matter).

    /// A point of the canvas, on screen.
    static func screenPoint(_ point: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX + point.x, y: canvas.maxY - point.y)
    }

    /// A point on screen, on the canvas.
    static func canvasPoint(_ point: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: point.x - canvas.minX, y: canvas.maxY - point.y)
    }

    /// Where an Imp `figure` points square, centred on a point of the canvas, is on screen.
    static func screenFrame(centre: CGPoint, figure: CGFloat, canvas: CGRect) -> CGRect {
        let c = screenPoint(centre, canvas: canvas)
        return CGRect(x: c.x - figure / 2, y: c.y - figure / 2, width: figure, height: figure)
    }

    /// A free spot for a new Imp: along the middle row first, then above and below it, from the
    /// centre outwards. Never on top of one already there while there is room.
    static func freePlace(taking taken: [CGPoint]) -> CGPoint {
        let rows: [CGFloat] = [0.58, 0.32, 0.82]
        let columns: [CGFloat] = [0.5, 0.3, 0.7, 0.12, 0.88]
        for y in rows {
            for x in columns where !taken.contains(where: { abs($0.x - x) < 0.14 && abs($0.y - y) < 0.2 }) {
                return CGPoint(x: x, y: y)
            }
        }
        let n = CGFloat(taken.count % 7)
        return CGPoint(x: 0.2 + 0.1 * n, y: 0.45 + 0.05 * n)
    }

    private static func clamp(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? (low + high) / 2 : min(max(v, low), high)
    }
}
