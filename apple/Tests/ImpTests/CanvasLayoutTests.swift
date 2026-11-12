import CoreGraphics
import Testing
@testable import Imp

@Suite struct CanvasLayoutTests {
    private let size = CGSize(width: 800, height: 600)

    @Test func anImpStaysWholeInsideTheCanvas() {
        let corner = CanvasLayout.point(of: CGPoint(x: 0, y: 1), in: size, figure: 112)
        #expect(corner.x >= 56 && corner.y <= 600 - 56 - CanvasLayout.nameRoom)
        let far = CanvasLayout.point(of: CGPoint(x: 3, y: -2), in: size, figure: 112)
        #expect(far.x <= 800 - 56 && far.y >= 56)
    }

    @Test func aTinyWindowCentresTheImp() {
        let p = CanvasLayout.point(of: CGPoint(x: 0.1, y: 0.1), in: CGSize(width: 60, height: 60), figure: 112)
        #expect(p.x == 30 && p.y.isFinite)
    }

    @Test func draggingKeepsAPlaceInsideAndRoundTrips() {
        let place = CanvasLayout.place(at: CGPoint(x: 400, y: 300), in: size, figure: 112)
        #expect(abs(place.x - 0.5) < 0.001 && abs(place.y - 0.5) < 0.001)
        let off = CanvasLayout.place(at: CGPoint(x: -500, y: 9000), in: size, figure: 112)
        let kept = CanvasLayout.point(of: off, in: size, figure: 112)
        #expect(kept.x >= 56 && kept.y <= 600)
    }

    @Test func newImpsDoNotLandOnEachOther() {
        var taken: [CGPoint] = []
        for _ in 0..<8 { taken.append(CanvasLayout.freePlace(taking: taken)) }
        for (i, a) in taken.enumerated() {
            for b in taken[(i + 1)...] { #expect(abs(a.x - b.x) >= 0.14 || abs(a.y - b.y) >= 0.2) }
        }
    }

    // MARK: Canvas and screen

    /// A canvas 800 x 600 whose top-left corner is at (100, 700) on a bottom-up screen.
    private let canvas = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func theCanvasFlipsTopDownIntoBottomUp() {
        #expect(CanvasLayout.screenPoint(CGPoint(x: 0, y: 0), canvas: canvas) == CGPoint(x: 100, y: 700))
        #expect(CanvasLayout.screenPoint(CGPoint(x: 800, y: 600), canvas: canvas) == CGPoint(x: 900, y: 100))
        let p = CGPoint(x: 123, y: 456)
        #expect(CanvasLayout.canvasPoint(CanvasLayout.screenPoint(p, canvas: canvas), canvas: canvas) == p)
    }

    @Test func anImpFrameOnScreenIsWhereItIsDrawn() {
        let frame = CanvasLayout.screenFrame(centre: CGPoint(x: 400, y: 300), figure: 112, canvas: canvas)
        #expect(frame == CGRect(x: 444, y: 344, width: 112, height: 112))
        // Dragged past the left edge: the frame is not clamped.
        let out = CanvasLayout.screenFrame(centre: CGPoint(x: -20, y: 10), figure: 112, canvas: canvas)
        #expect(out.minX == 100 - 20 - 56 && out.midY == 690)
    }

    @Test func anImpDroppedUnderThePointerLandsUnderIt() {
        // A free Imp held 10 right and 20 above its middle, dropped with the pointer at (500, 400) on screen.
        let pointer = CGPoint(x: 500, y: 400), grab = CGSize(width: 10, height: 20)
        let centre = CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height)
        let place = CanvasLayout.place(at: CanvasLayout.canvasPoint(centre, canvas: canvas), in: canvas.size, figure: 112)
        let drawn = CanvasLayout.point(of: place, in: canvas.size, figure: 112)
        let back = CanvasLayout.screenPoint(drawn, canvas: canvas)
        #expect(abs(back.x - centre.x) < 0.001 && abs(back.y - centre.y) < 0.001)
    }
}
