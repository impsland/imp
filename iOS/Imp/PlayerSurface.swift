import AVKit
import SwiftUI

/// UIKit's own player, with its standard controls. SwiftUI's `VideoPlayer` is not used: it lives in
/// an overlay framework that needs AVKit already loaded, and an app that names no AVKit type of its
/// own isn't linked to AVKit, so the first video stopped the app.
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
