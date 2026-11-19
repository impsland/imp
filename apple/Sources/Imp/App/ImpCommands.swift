import ImpDesign
import ImpKit
import SwiftUI

/// The app's menu bar menus. SwiftUI owns the main menu of an app with the SwiftUI life cycle and builds
/// it from the scene's commands, so the menus are declared here and nowhere else. A menu installed on
/// `NSApp.mainMenu` by hand is replaced the next time SwiftUI updates its scenes, and with it went the
/// Edit menu, whose key equivalents are what carry ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z to the text field that has the
/// keyboard. The Edit and Window menus are the standard ones SwiftUI provides.
struct ImpCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) { SettingsCommand(model: model) }
        CommandGroup(replacing: .newItem) { CanvasCommands(model: model) }
        CommandMenu("menu.bar.imps") { SelectedImpCommands(model: model) }
    }
}

/// Settings…, in the app menu.
private struct SettingsCommand: View {
    let model: AppModel

    var body: some View {
        Button("menu.canvas.settings") {
            HomeWindow.shared.reveal(model)
            HomeActions(model: model, router: HomeWindow.shared.router).openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// The File menu: what a right click on the canvas offers, and putting the plain background back.
private struct CanvasCommands: View {
    let model: AppModel

    private var actions: HomeActions { HomeActions(model: model, router: HomeWindow.shared.router) }

    var body: some View {
        Button("menu.canvas.new_imp") {
            HomeWindow.shared.reveal(model)
            actions.newImp()
        }
        .keyboardShortcut("n", modifiers: .command)
        if model.hiddenCount > 0 {
            Button(words("menu.canvas.show_hidden", model.hiddenCount)) { actions.showHidden() }
        }
        Button("menu.canvas.reset_background") { actions.resetBackground() }
            .disabled(model.prefs.background == RoomBackground.defaultHTML)
    }
}

/// The Imps menu: the menu of the Imp that has the keyboard on the canvas. With none chosen, or on a
/// settings screen, every item is dimmed.
private struct SelectedImpCommands: View {
    let model: AppModel

    private var router: HomeRouter { HomeWindow.shared.router }

    private var selected: UUID? {
        guard router.screen == .home, let id = router.selection, model.isOnCanvas(id) else { return nil }
        return id
    }

    var body: some View {
        ImpContextMenu(model: model, router: router, id: selected)
            .disabled(selected == nil)
    }
}
