import CoreGraphics
import Testing
@testable import ImpKit

@Suite struct MediaTests {
    @Test func imageEncodeDownscales() throws {
        let ctx = CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        let enc = try #require(EncodedImage.encode(ctx.makeImage()!, maxPixel: 1500))
        let back = try #require(EncodedImage.decode(enc.data))
        #expect(back.width == 1500 && back.height == 500)
        #expect(enc.dataURL.hasPrefix("data:image/"))
    }
}
