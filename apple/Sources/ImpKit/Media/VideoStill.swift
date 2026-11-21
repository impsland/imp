import AVFoundation
import CoreGraphics

/// A frame of a video file, for its thumbnail.
public enum VideoStill {
    public static func frame(of url: URL, maxPixel: CGFloat = 240) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }
}
