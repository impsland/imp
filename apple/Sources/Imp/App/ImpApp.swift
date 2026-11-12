import AppKit
import SwiftUI

/// The app's one scene: the menu bar item, with the app's menus as its commands. `MenuBarExtra` with the window
/// style keeps the item selected for as long as its panel is open and closes the panel on a click elsewhere or Esc.
/// `windowResizability(.contentSize)` ties the panel's window to its content, so the window grows and shrinks
/// with the list of Imps instead of keeping the size it first opened with. Everything else (the Imps on the
/// desktop, the home window) is set up by `AppDelegate`.
struct ImpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: delegate.model)
        } label: {
            Image(nsImage: StatusIcon.image)
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)
        .commands { ImpCommands(model: delegate.model) }
    }
}
