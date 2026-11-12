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
            .frame(width: WindowSizing.defaultMinimum.width, height: WindowSizing.defaultMinimum.height)
    }

    /// A picture in the app's own folder: stripes, so a fill and a tile can be told apart.
    static func picture(name: String) -> String {
        let size = CGSize(width: 96, height: 96)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.2, blue: 0.34, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.3, green: 0.4, blue: 0.62, alpha: 1).setFill()
            for i in stride(from: 0.0, to: 96.0, by: 24.0) { NSRect(x: i, y: 0, width: 8, height: 96).fill() }
            return true
        }
        let folder = BackgroundFiles.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let url = BackgroundFiles.url(of: name) {
            try? png.write(to: url)
        }
        return name
    }
}

#Preview("Empty canvas") {
    ZStack {
        CanvasBackdrop(background: CanvasBackground())
        EmptyCanvas(action: {})
    }
    .frame(width: WindowSizing.defaultMinimum.width, height: WindowSizing.defaultMinimum.height)
}

#Preview("A few Imps") {
    PreviewHome.window(PreviewHome.model(imps: 4))
}

#Preview("A picture") {
    let model = PreviewHome.model(imps: 3)
    model.prefs.background.kind = .picture
    model.prefs.background.image = PreviewHome.picture(name: "preview.png")
    return PreviewHome.window(model)
}

#Preview("A tile") {
    let model = PreviewHome.model(imps: 3)
    model.prefs.background.kind = .tile
    model.prefs.background.image = PreviewHome.picture(name: "preview.png")
    return PreviewHome.window(model)
}
