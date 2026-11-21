import CoreGraphics

/// The arithmetic of the playful camera: where the Imps peek in, what part of the photo the screen showed, and
/// where a spot on the screen lands in the photo. Pure, so it is tested without a camera.
public enum CameraGeometry {
    /// An Imp's side as a share of the screen's width.
    public static let impShare: CGFloat = 0.52
    /// How much of an Imp hangs outside the screen at its spot.
    public static let outside: CGFloat = 0.4

    /// The frames (screen points) where `count` Imps of side `side` peek in: bottom-left corner, top-right corner,
    /// then the left side, the right side, bottom-right and top-left. More than six reuse the spots.
    public static func spots(count: Int, in screen: CGSize, side: CGFloat) -> [CGRect] {
        guard count > 0, screen.width > 0, screen.height > 0 else { return [] }
        let out = side * outside
        let near = -out, farX = screen.width - side + out, farY = screen.height - side + out
        let sideY = { (share: CGFloat) in screen.height * share - side / 2 }
        let all = [
            CGRect(x: near, y: farY, width: side, height: side),
            CGRect(x: farX, y: near, width: side, height: side),
            CGRect(x: near, y: sideY(0.38), width: side, height: side),
            CGRect(x: farX, y: sideY(0.62), width: side, height: side),
            CGRect(x: farX, y: farY, width: side, height: side),
            CGRect(x: near, y: near, width: side, height: side),
        ]
        return (0..<count).map { all[$0 % all.count] }
    }

    /// Where an Imp starts before it springs to `spot`: further out through the edge it peeks over.
    public static func start(for spot: CGRect, in screen: CGSize) -> CGRect {
        let push = spot.width * 0.7
        let dx: CGFloat = spot.midX < screen.width / 2 ? -push : push
        let dy: CGFloat = abs(spot.midY - screen.height / 2) < screen.height * 0.3 ? 0 : (spot.midY < screen.height / 2 ? -push : push)
        return spot.offsetBy(dx: dx, dy: dy)
    }

    /// Keeps an Imp's frame reachable: at least 55% of it stays on the screen.
    public static func clamped(_ frame: CGRect, in screen: CGSize) -> CGRect {
        let out = frame.width * 0.45
        let x = min(max(frame.minX, -out), screen.width - frame.width + out)
        let y = min(max(frame.minY, -out), screen.height - frame.height + out)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// The part of a photo (pixels) that a view of `view` points shows when the photo fills it (aspect fill, centred).
    public static func fillCrop(photo: CGSize, view: CGSize) -> CGRect {
        guard photo.width > 0, photo.height > 0, view.width > 0, view.height > 0 else { return CGRect(origin: .zero, size: photo) }
        let scale = max(view.width / photo.width, view.height / photo.height)
        let w = view.width / scale, h = view.height / scale
        return CGRect(x: (photo.width - w) / 2, y: (photo.height - h) / 2, width: w, height: h)
    }

    /// A frame in view points as pixels of the photo.
    public static func photoFrame(_ frame: CGRect, view: CGSize, photo: CGSize) -> CGRect {
        let crop = fillCrop(photo: photo, view: view)
        let k = crop.width / view.width
        return CGRect(x: crop.minX + frame.minX * k, y: crop.minY + frame.minY * k, width: frame.width * k, height: frame.height * k)
    }

    /// A frame in view points as pixels of the cropped picture (the photo cut to what the view shows).
    public static func croppedFrame(_ frame: CGRect, view: CGSize, cropped: CGSize) -> CGRect {
        let k = cropped.width / view.width
        return CGRect(x: frame.minX * k, y: frame.minY * k, width: frame.width * k, height: frame.height * k)
    }
}
