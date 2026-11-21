import AVKit
import SwiftUI

/// UIKit's own player, with its standard controls. SwiftUI's `VideoPlayer` is not used: it needs AVKit
/// to be loaded already, and an app that names no AVKit type of its own does not link AVKit, so a
/// first video would stop the app.
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
