import SwiftUI

/// The dungeon wall: the gradient, the bricks and a soft floor so the room has a bottom. The Mac's
/// stage and the iPhone's stage each put their own floating embers on top of it.
public struct DungeonWall: View {
    var brickOpacity: Double
    var floor: Double
    var floorStart: Double

    public init(brickOpacity: Double = 0.045, floor: Double = 0.3, floorStart: Double = 0.7) {
        self.brickOpacity = brickOpacity
        self.floor = floor
        self.floorStart = floorStart
    }

    public var body: some View {
        ZStack {
            Dungeon.wall
            Canvas { ctx, size in Self.bricks(&ctx, size: size, opacity: brickOpacity) }
            LinearGradient(colors: [.clear, .black.opacity(floor)], startPoint: .init(x: 0.5, y: floorStart), endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Rows of rounded bricks, each a little lighter or darker than its neighbour.
    nonisolated public static func bricks(_ ctx: inout GraphicsContext, size: CGSize, opacity: Double) {
        let bw: CGFloat = 64, bh: CGFloat = 28
        var row = 0
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = row % 2 == 0 ? 0 : -bw / 2
            while x < size.width {
                let r = CGRect(x: x + 2, y: y + 2, width: bw - 4, height: bh - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(.white.opacity(opacity * (0.6 + 0.4 * noise(row, Int(x))))))
                x += bw
            }
            y += bh
            row += 1
        }
    }

    /// Cheap, stable pseudo-randomness in 0…1.
    nonisolated public static func noise(_ a: Int, _ b: Int) -> Double {
        let v = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }
}
