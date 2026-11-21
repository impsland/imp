import CoreGraphics
import Testing
@testable import ImpKit

@Suite struct CameraGeometryTests {
    let screen = CGSize(width: 400, height: 800)

    @Test func spotsPeekInFromTheEdges() {
        let side: CGFloat = 168
        let spots = CameraGeometry.spots(count: 6, in: screen, side: side)
        #expect(spots.count == 6)
        // Bottom-left first, top-right second, each about 40% outside.
        #expect(spots[0].minX == -side * 0.4 && spots[0].maxY == 800 + side * 0.4)
        #expect(spots[1].maxX == 400 + side * 0.4 && spots[1].minY == -side * 0.4)
        for spot in spots {
            let visible = spot.intersection(CGRect(origin: .zero, size: screen))
            #expect(visible.width * visible.height >= side * side * 0.3)
            #expect(visible.width * visible.height <= side * side * 0.7)
        }
    }

    @Test func fewerAndMoreImps() {
        #expect(CameraGeometry.spots(count: 0, in: screen, side: 100).isEmpty)
        #expect(CameraGeometry.spots(count: 1, in: screen, side: 100).count == 1)
        let eight = CameraGeometry.spots(count: 8, in: screen, side: 100)
        #expect(eight[6] == eight[0])
    }

    @Test func startsOutsideTheScreen() {
        let spot = CameraGeometry.spots(count: 1, in: screen, side: 168)[0]
        let start = CameraGeometry.start(for: spot, in: screen)
        #expect(start.maxX < 0 || start.minY > 800)
    }

    @Test func aspectFillCrop() {
        // A 4:3 landscape-turned-portrait photo (3000x4000) in a tall view (400x800): the sides are cut.
        let crop = CameraGeometry.fillCrop(photo: CGSize(width: 3000, height: 4000), view: screen)
        #expect(crop.height == 4000 && crop.width == 2000 && crop.minX == 500 && crop.minY == 0)
        // A wide photo in a wide view of the same shape: all of it.
        let same = CameraGeometry.fillCrop(photo: CGSize(width: 800, height: 400), view: CGSize(width: 200, height: 100))
        #expect(same == CGRect(x: 0, y: 0, width: 800, height: 400))
        // A tall photo in a wide view: the top and bottom are cut.
        let tall = CameraGeometry.fillCrop(photo: CGSize(width: 1000, height: 2000), view: CGSize(width: 100, height: 100))
        #expect(tall == CGRect(x: 0, y: 500, width: 1000, height: 1000))
    }

    @Test func viewFrameInPhotoPixels() {
        let photo = CGSize(width: 3000, height: 4000)
        let frame = CGRect(x: 100, y: 200, width: 168, height: 168)
        let mapped = CameraGeometry.photoFrame(frame, view: screen, photo: photo)
        #expect(mapped == CGRect(x: 500 + 500, y: 1000, width: 840, height: 840))
        let cropped = CameraGeometry.croppedFrame(frame, view: screen, cropped: CGSize(width: 2000, height: 4000))
        #expect(cropped == CGRect(x: 500, y: 1000, width: 840, height: 840))
    }

    @Test func clampKeepsMostOfAnImpOnScreen() {
        let far = CameraGeometry.clamped(CGRect(x: -900, y: 5000, width: 100, height: 100), in: screen)
        #expect(far.minX == -45 && far.maxY == 845)
    }
}
