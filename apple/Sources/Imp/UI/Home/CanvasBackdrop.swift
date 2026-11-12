import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// What the canvas shows behind the Imps: the app's plain surface, a colour, a picture that fills
/// the window, or a tile that repeats. It is the one backdrop under every screen of the window
/// (see `HomeView`). It never moves, so it costs nothing to keep on screen.
struct CanvasBackdrop: View {
    let background: CanvasBackground

    var body: some View {
        ZStack {
            switch background.kind {
            case .theme:
                Backdrop()
            case .colour:
                Color(.sRGB, red: background.colour.red, green: background.colour.green, blue: background.colour.blue)
            case .picture, .tile:
                // Whatever can't be read leaves the plain surface showing.
                Backdrop()
                if let image = Self.image(background.image) {
                    if background.kind == .picture {
                        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                    } else {
                        Image(nsImage: image).resizable(resizingMode: .tile)
                    }
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func image(_ name: String?) -> NSImage? {
        name.flatMap { BackgroundFiles.url(of: $0) }.flatMap { NSImage(contentsOf: $0) }
    }
}
