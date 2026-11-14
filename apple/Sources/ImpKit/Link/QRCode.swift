import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A QR code for a piece of text, drawn the way a camera reads it best: dark squares on white, with a
/// white margin of four squares on every side (the quiet zone the standard asks for), every square a
/// whole number of pixels so the edges stay sharp. The Mac and the iPhone both show this one picture.
public enum QRCode {
    /// The margin around the squares, in squares.
    public static let quietModules = 4

    /// The squares of the code for `text`: `side` by `side`, row by row, true where a square is dark.
    public struct Matrix: Equatable, Sendable {
        public let side: Int
        public let dark: [Bool]
    }

    /// The code's squares, at medium error correction. Nil when the text is too long for a code.
    public static func matrix(for text: String) -> Matrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let side = Int(output.extent.width)
        guard side > 0, Int(output.extent.height) == side else { return nil }
        // One pixel per square, read back as RGBA in a fixed colour space, so the answer does not
        // depend on how the filter happens to tag its picture.
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        CIContext().render(output, toBitmap: &pixels, rowBytes: side * 4, bounds: output.extent,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let half = UInt8.max / 2
        // The bitmap's first row is the top of the code.
        let all = (0..<side * side).map { index in
            pixels[index * 4 + 3] > half && pixels[index * 4] < half
        }
        // The filter adds a white margin of its own. Cut it off so the matrix is only the code (its finder
        // squares touch the corners). The margin is drawn once, at the size the standard asks for.
        let used = all.indices.filter { all[$0] }
        guard !used.isEmpty else { return nil }
        let rows = used.map { $0 / side }, columns = used.map { $0 % side }
        guard let top = rows.min(), let bottom = rows.max(), let left = columns.min(), let right = columns.max(),
              bottom - top == right - left else { return nil }
        let inner = bottom - top + 1
        let dark = (0..<inner * inner).map { all[(top + $0 / inner) * side + left + $0 % inner] }
        return Matrix(side: inner, dark: dark)
    }

    /// The finished picture: `moduleSize` pixels per square, dark on white, with the quiet zone.
    public static func image(for text: String, moduleSize: Int = 8) -> CGImage? {
        guard moduleSize > 0, let matrix = matrix(for: text) else { return nil }
        let squares = matrix.side + 2 * quietModules
        let pixels = squares * moduleSize
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.setFillColor(gray: 0, alpha: 1)
        context.setShouldAntialias(false)
        for (index, isDark) in matrix.dark.enumerated() where isDark {
            let row = index / matrix.side, column = index % matrix.side
            // Core Graphics counts rows from the bottom.
            let y = (squares - 1 - (row + quietModules)) * moduleSize
            context.fill(CGRect(x: (column + quietModules) * moduleSize, y: y, width: moduleSize, height: moduleSize))
        }
        return context.makeImage()
    }
}
