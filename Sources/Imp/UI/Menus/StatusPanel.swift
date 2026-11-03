import AppKit
import SwiftUI

/// The menu bar panel: a row of buttons (Imps, Hide, Settings, Quit). Everything else lives in the app's window and in
/// each Imp's own right-click menu. Each command closes the panel first, then runs within the click, so a window
/// opened here is brought forward as the user's own request (see `HomeWindow.bringToFront`).
struct StatusPanel: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let anyoneOut = !model.imps.isEmpty
        let shown = !model.anyHiding
        QuickBar(buttons: [
            QuickBar.Item(icon: "house.fill", title: "Imps", help: "Open the Imps' home (⌘,)") {
                run { HomeWindow.shared.reveal(model) }
            },
            QuickBar.Item(icon: shown ? "eye.slash.fill" : "eye.fill", title: shown ? "Hide" : "Show",
                          help: anyoneOut ? (shown ? "Hide the Imps on your desktop" : "Show the Imps again")
                                          : "No Imps are out on the desktop",
                          enabled: anyoneOut) {
                run { model.setHidden(!model.anyHiding) }
            },
            QuickBar.Item(icon: "gearshape.fill", title: "Settings", help: "Settings for all Imps: services, talking, animations, permissions, app") {
                run { HomeWindow.shared.showGeneral(model) }
            },
            QuickBar.Item(icon: "power", title: "Quit", help: "Quit Imp (⌘Q)") {
                run { NSApp.terminate(nil) }
            },
        ])
        .padding(.vertical, 5)
    }

    private func run(_ action: () -> Void) {
        dismiss()
        action()
    }
}
