#if DEBUG
import ImpKit
import SwiftUI

/// Draws the app icon with the Mac's renderer (`scripts/make-icon.sh` runs the app with `-renderIcon <path>`).
@MainActor
enum IconRender {
    static func run(to path: String) {
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.10, blue: 0.19), Color(red: 0.10, green: 0.05, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                SoftLight.glow(&ctx, at: CGPoint(x: size.width / 2, y: size.height * 0.56), radius: size.width * 0.55,
                               color: Dungeon.ember, opacity: 0.38, squash: 0.9)
            }
            Canvas { ctx, size in
                let puppet = Puppet()
                var cue = Puppet.Cue(mood: .content, step: nil, hue: 0, traits: .plain)
                cue.breathing = false
                var frame = puppet.frame(cue, at: 0)
                for i in 1...30 { frame = puppet.frame(cue, at: Double(i) / 30) }
                ImpRenderer.draw(&ctx, size: size, face: frame.face, motion: frame.motion, shadow: false)
            }
            .frame(width: 900, height: 900)
            .offset(y: -50)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        if let data = renderer.uiImage?.pngData() { try? data.write(to: URL(fileURLWithPath: path)) }
        exit(0)
    }
}
#endif
