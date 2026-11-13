import ImpDesign
import ImpKit
import SwiftUI

/// The menu for empty space: a right click on the canvas. One level, no submenus. The same actions are
/// the corner buttons and the menu bar. The background lives in Settings, one click away.
struct CanvasMenu: View {
    let model: AppModel
    let router: HomeRouter

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        Button { actions.newImp() } label: { Text("menu.canvas.new_imp") }
            .keyboardShortcut("n", modifiers: .command)
        if model.hiddenCount > 0 {
            Button { actions.showHidden() } label: { Text(words("menu.canvas.show_hidden", model.hiddenCount)) }
        }
        Divider()
        Button { actions.openSettings() } label: { Text("menu.canvas.settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

/// The menu on an Imp: a right click on it, and the menu bar's Imps menu for the chosen one. One level,
/// no submenus. The menu bar passes nil while no Imp is chosen, and dims the whole menu.
struct ImpContextMenu: View {
    let model: AppModel
    let router: HomeRouter
    let id: UUID?

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        Button { if let id { actions.openImpSettings(id) } } label: { Text("menu.imp.settings") }
            .keyboardShortcut("i", modifiers: .command)
        Button { if let id { actions.hide(id) } } label: { Text("menu.imp.hide") }
        Button { if let id { actions.copyKit(id) } } label: { Text("menu.imp.copy_kit") }
        Button { if let id { actions.copyLink(id) } } label: { Text("menu.imp.copy_link") }
            .disabled(!(id.map(actions.canShareLink) ?? false))
        Button { if let id { actions.toggleActive(id) } } label: { Text(id.map(actions.releaseTitle) ?? String(localized: "menu.imp.let_out")) }
            .disabled(!(id.map(actions.canRelease) ?? false))
        Divider()
        Button(role: .destructive) { if let id { actions.askGoodbye(id) } } label: { Text("menu.imp.goodbye") }
            .disabled(!actions.canSayGoodbye)
    }
}
