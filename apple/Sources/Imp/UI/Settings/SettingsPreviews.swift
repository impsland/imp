import ImpDesign
import ImpKit
import SwiftUI

/// The main states of one Imp's settings: awake with a Brain, asleep without one, the plain list in a
/// narrow window, and the Tools and Triggers panels open beside the Imp.
@MainActor
private enum PreviewSettings {
    static func model(brain: Bool) -> (AppModel, UUID) {
        let model = AppModel(persist: false)
        model.prefs = ImpPreferences()
        if brain { model.prefs.ai.add(Service(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2")) }
        let id = model.addImp()
        var trigger = Shortcut(name: "Translate", hotkey: nil, steps: [Step(.ask, value: "Translate this into English.", clipboard: true)])
        trigger.performer = id
        model.prefs.shortcuts = [trigger]
        return (model, id)
    }

    static func view(brain: Bool, open: ImpSetting? = nil) -> some View {
        let (model, id) = model(brain: brain)
        return ImpSettingsView(model: model, router: HomeRouter(), id: id, open: open)
            .background(Tone.deep)
    }
}

#Preview("Awake, markers around the Imp") {
    PreviewSettings.view(brain: true).frame(width: PreviewSize.w760, height: PreviewSize.h600)
}

#Preview("Asleep, no Brain") {
    PreviewSettings.view(brain: false).frame(width: PreviewSize.w760, height: PreviewSize.h600)
}

#Preview("Plain list in a narrow window") {
    PreviewSettings.view(brain: true).frame(width: PreviewSize.w440, height: PreviewSize.h640)
}

#Preview("Brain panel open") {
    PreviewSettings.view(brain: false, open: .brain).frame(width: PreviewSize.w1100, height: PreviewSize.h640)
}

#Preview("Tools panel open") {
    PreviewSettings.view(brain: true, open: .tools).frame(width: PreviewSize.w1100, height: PreviewSize.h640)
}

#Preview("Triggers panel open") {
    PreviewSettings.view(brain: true, open: .triggers).frame(width: PreviewSize.w1100, height: PreviewSize.h640)
}

/// The window sizes the previews are drawn at.
private enum PreviewSize {
    static let w760: CGFloat = 760
    static let w440: CGFloat = 440
    static let w1100: CGFloat = 1100
    static let h600: CGFloat = 600
    static let h640: CGFloat = 640
}
