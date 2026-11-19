import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The home screen's main states, for Xcode's canvas: no Imps, a few Imps, and a picture behind them.
@MainActor
private enum PreviewHome {
    static func model(imps: Int) -> AppModel {
        let model = AppModel(persist: false)
        for _ in 0..<max(0, imps - 1) { model.addImp() }
        for (i, hue) in [0.08, 0.57, 0.33, 0.8].enumerated() where model.prefs.imps.indices.contains(i) {
            model.prefs.imps[i].hue = hue
            model.prefs.imps[i].name = ["Dot", "Bumble", "Pip", "Mo"][i]
        }
        return model
    }

    static func window(_ model: AppModel) -> some View {
        HomeView(model: model, router: HomeRouter())
            .frame(width: WindowSizing.minimum.width, height: WindowSizing.minimum.height)
    }
}

#Preview("Empty canvas") {
    ZStack {
        CanvasBackdrop(html: RoomBackground.defaultHTML)
        EmptyCanvas(action: {})
    }
    .frame(width: WindowSizing.minimum.width, height: WindowSizing.minimum.height)
}

#Preview("A few Imps") {
    PreviewHome.window(PreviewHome.model(imps: 4))
}

#Preview("A starry sky") {
    let model = PreviewHome.model(imps: 3)
    model.prefs.background = "<html><body style='margin:0;height:100vh;background:radial-gradient(#223,#000)'></body></html>"
    return PreviewHome.window(model)
}
