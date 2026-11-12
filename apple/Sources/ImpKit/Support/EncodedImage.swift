import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to upload as a data URL.
public struct EncodedImage: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// Downscales to `maxPixel` on the long side and encodes as PNG (or JPEG when opaque & large),
    /// keeping uploads small without visibly hurting edits.
    public static func encode(_ image: CGImage, maxPixel: Int = 2048) -> EncodedImage? {
        var cg = image
        let longSide = max(image.width, image.height)
        if longSide > maxPixel {
            let scale = Double(maxPixel) / Double(longSide)
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            cg = scaled
        }
        let opaque: Bool = switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
        let useJPEG = opaque && cg.width * cg.height > 1_000_000
        let type = useJPEG ? UTType.jpeg : UTType.png
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = useJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return EncodedImage(data: out as Data, mimeType: useJPEG ? "image/jpeg" : "image/png")
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
