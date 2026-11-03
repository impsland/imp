import AppKit
import SwiftUI

/// The app's one scene: the menu bar item. `MenuBarExtra` with the window style keeps the item selected for as long
/// as its panel is open, closes the panel on a click elsewhere or Esc, and sizes it to its content. Everything else
/// (the Imps on the desktop, the home window, the main menu) is set up by `AppDelegate`.
struct ImpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: delegate.model)
        } label: {
            Image(nsImage: StatusIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}
