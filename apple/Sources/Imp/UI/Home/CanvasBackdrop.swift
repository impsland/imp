import ImpDesign
import ImpKit
import SwiftUI

/// What the canvas shows behind the Imps: the HTML document the Imps set (`RoomBackground`), over the
/// app's plain surface, which shows until the document has drawn. It is the one backdrop under every
/// screen of the window (see `HomeView`).
struct CanvasBackdrop: View {
    let html: String
    /// It may move now: the window can be seen and the canvas is showing.
    var live = true

    var body: some View {
        ZStack {
            Backdrop()
            HTMLBackdrop(html: html, plain: RoomBackground.defaultHTML, live: live)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
