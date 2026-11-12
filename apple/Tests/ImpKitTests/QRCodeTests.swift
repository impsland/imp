import CoreGraphics
import Foundation
import Testing
import Vision
@testable import ImpKit

/// The link code both devices show: a camera must be able to read it back, so it is dark squares on a
/// white page with a margin, never a plain white square.
@Suite struct QRCodeTests {
    private static let link = "implink://join?device=7C9E6679-7425-40DE-944B-E07FC1F90AE7&key=Zm9vYmFyYmF6cXV4&door=aGVsbG8&routes=mac.local"

    /// Grey level (0 to 255) of every pixel, row by row.
    private static func grey(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    @Test func aCameraReadsTheSameLinkBack() throws {
        let image = try #require(QRCode.image(for: Self.link))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        #expect(payloads == [Self.link])
    }

    @Test func itHasDarkSquaresAndALightMargin() throws {
        let image = try #require(QRCode.image(for: Self.link, moduleSize: 8))
        let pixels = Self.grey(image)
        #expect(pixels.contains { $0 < 64 })
        #expect(pixels.contains { $0 > 192 })
        // Most of a code on a page is white, never mostly dark.
        #expect(pixels.filter { $0 < 128 }.count < pixels.count / 2)
        // The margin is at least four squares of white on every side.
        let margin = QRCode.quietModules * 8
        let width = image.width, height = image.height
        var marginIsWhite = true
        for y in 0..<height {
            for x in 0..<width where x < margin || y < margin || x >= width - margin || y >= height - margin {
                if pixels[y * width + x] != 255 { marginIsWhite = false }
            }
        }
        #expect(marginIsWhite)
    }

    @Test func everySquareIsWholePixelsAndTheEdgesAreSharp() throws {
        let image = try #require(QRCode.image(for: Self.link, moduleSize: 6))
        let matrix = try #require(QRCode.matrix(for: Self.link))
        #expect(image.width == (matrix.side + 2 * QRCode.quietModules) * 6)
        // Only pure black and pure white: nothing blurred between them.
        #expect(Set(Self.grey(image)) == [0, 255])
    }

    @Test func theFinderSquaresSitInThreeCorners() throws {
        let matrix = try #require(QRCode.matrix(for: Self.link))
        let side = matrix.side
        func dark(_ row: Int, _ column: Int) -> Bool { matrix.dark[row * side + column] }
        #expect(dark(0, 0) && dark(0, side - 1) && dark(side - 1, 0))
    }

    @Test func aLinkTooLongForACodeGivesNothing() {
        #expect(QRCode.image(for: String(repeating: "x", count: 5000)) == nil)
    }
}
