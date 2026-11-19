import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The menu for empty space: a right click on the canvas. A card of buttons (`MenuCard`): New Imp and Settings,
/// with Hidden (n) and Select All Imps beside them when they apply. The same actions are the corner buttons and the
/// menu bar. The background lives in Settings, one click away.
@MainActor
final class CanvasEmptyMenu {
    private let model: AppModel
    private let router: HomeRouter
    private let card = CardMenu()

    init(model: AppModel, router: HomeRouter) {
        self.model = model
        self.router = router
    }

    func make() -> NSMenu {
        let actions = HomeActions(model: model, router: router)
        let card = card
        var items = [MenuItem(id: "new", icon: "plus", title: String(localized: "menu.canvas.new_imp")) { card.later { actions.newImp() } }]
        if model.hiddenCount > 0 {
            items.append(MenuItem(id: "hidden", icon: "eye.fill", title: words("menu.canvas.show_hidden", model.hiddenCount)) {
                card.later { actions.showHidden() }
            })
        }
        let here = model.prefs.imps.map(\.id).filter(model.isOnCanvas)
        if here.count > 1 {
            items.append(MenuItem(id: "all", icon: "checkmark.circle.fill", title: String(localized: "menu.canvas.select_all")) { [router] in
                card.later { router.pickAll(here) }
            })
        }
        items.append(MenuItem(id: "settings", icon: "gearshape.fill", title: String(localized: "menu.canvas.settings")) {
            card.later { actions.openSettings() }
        })
        return card.make(MenuCard { MenuGrid(items: items) })
    }
}

/// The menu bar's Imps menu for the chosen one: one level, no submenus. The menu bar passes nil while no Imp is
/// chosen, and dims the whole menu. A right click on an Imp opens `CanvasImpMenu` instead.
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

/// The menu of an Imp in the window, from a right click (or a Control-click) on it: the same card as on the
/// desktop (`ImpMenuCard`, with Free where the desktop has Home), then Copy kit and Copy link as pills and
/// Goodbye as the wide button at the bottom.
@MainActor
final class CanvasImpMenu {
    private let model: AppModel
    private let router: HomeRouter
    private let id: UUID
    private let card = CardMenu()

    init(model: AppModel, router: HomeRouter, id: UUID) {
        self.model = model
        self.router = router
        self.id = id
    }

    func make() -> NSMenu {
        guard let imp = model.profile(id) else { return NSMenu() }
        let actions = HomeActions(model: model, router: router)
        let card = card, id = id
        let ready = model.isReady(id)
        let status = imp.awayOn != nil ? words("imp.state.away", model.link.name(of: imp.awayOn ?? id) ?? "iPhone")
            : ready ? String(localized: "Awake") : String(localized: "Needs a brain")
        return card.make(ImpMenuCard(ready: ready, name: imp.name, status: status, hue: imp.hue, scale: imp.scale, place: .home) { action in
            switch action {
            case .talk: card.later { actions.talk(id) }
            case .type: card.later { actions.type(id) }
            case .chat: card.later { actions.chat(id) }
            case .hide: card.later { actions.hide(id) }
            case .move: card.later { actions.toggleActive(id) }
            case .settings: card.later { actions.openImpSettings(id) }
            case .size(let scale): actions.restyle(id) { $0.scale = scale }
            case .colour(let hue): actions.restyle(id) { $0.hue = hue }
            }
        } extra: {
            MenuPills(items: [
                MenuItem(id: "kit", icon: "shippingbox.fill", title: String(localized: "menu.imp.copy_kit")) { card.later { actions.copyKit(id) } },
                MenuItem(id: "link", icon: "link", title: String(localized: "menu.imp.copy_link"), enabled: actions.canShareLink(id)) {
                    card.later { actions.copyLink(id) }
                },
            ])
            MenuDangerButton(item: MenuItem(id: "goodbye", icon: "trash", title: String(localized: "menu.imp.goodbye"),
                                            enabled: actions.canSayGoodbye) { card.later { actions.askGoodbye(id) } })
        })
    }
}

/// The menu of several Imps picked together (`ImpPicks`), from a right click on any of them: the group card
/// (`GroupMenuCard`), one Brain for all as pills (it applies at once and the menu stays open), and Goodbye to
/// all of them, asked once.
@MainActor
final class CanvasGroupMenu {
    private let model: AppModel
    private let router: HomeRouter
    private let ids: [UUID]
    private let card = CardMenu()

    init(model: AppModel, router: HomeRouter, ids: [UUID]) {
        self.model = model
        self.router = router
        self.ids = ids
    }

    func make() -> NSMenu {
        let actions = HomeActions(model: model, router: router)
        let card = card, ids = ids
        let imps = ids.compactMap(model.profile)
        return card.make(GroupMenuCard(names: imps.map(\.name), hues: imps.map(\.hue), scales: imps.map(\.scale)) { action in
            switch action {
            case .hide: card.later { actions.hide(ids) }
            case .free: card.later { actions.free(ids) }
            case .kit: card.later { actions.copyKit(ids) }
            case .size(let scale): actions.restyle(ids) { $0.scale = scale }
            case .colour(let hue): actions.restyle(ids) { $0.hue = hue }
            }
        } extra: {
            GroupBrainPills(services: model.prefs.ai.services,
                            current: Self.brain(of: imps)) { actions.setBrain(ids, $0) }
            MenuDangerButton(item: MenuItem(id: "goodbye", icon: "trash", title: words("menu.group.goodbye", ids.count),
                                            enabled: actions.canSayGoodbye(to: ids)) {
                card.later { actions.askGoodbye(ids) }
            })
        })
    }

    /// The Brain every one of them has, if they all have the same: `.some(nil)` is the shared one, nil is mixed.
    private static func brain(of imps: [ImpProfile]) -> UUID?? {
        let services = Set(imps.map { $0.brain?.service })
        return services.count == 1 ? .some(services.first ?? nil) : nil
    }
}

/// One Brain for several Imps: Shared, or one of the services. The pick shows at once and applies at once.
private struct GroupBrainPills: View {
    let services: [Service]
    /// `.some(nil)` is the shared Brain, nil is a mix.
    @State var current: UUID??
    let pick: (Brain?) -> Void

    var body: some View {
        var items = [MenuItem(id: "shared", icon: "person.3.fill", title: String(localized: "brain.use_app"), on: current == .some(nil)) {
            current = .some(nil)
            pick(nil)
        }]
        for service in services {
            items.append(MenuItem(id: service.id.uuidString, icon: "brain", title: service.label, on: current == .some(service.id)) {
                current = .some(service.id)
                pick(Brain(service: service.id))
            })
        }
        return MenuPills(title: String(localized: "brain.title"), items: items)
    }
}

/// Opens an AppKit menu on a right click or a Control-click, and lets every other click through to the
/// SwiftUI view under it (taps, double clicks and drags keep working). SwiftUI's `contextMenu` can only
/// list items, and the Imp's menu starts with a card of buttons.
struct SecondaryClickMenu: NSViewRepresentable {
    let make: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.make = make
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.make = make }

    final class Catcher: NSView {
        var make: (@MainActor () -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { make?() }

        /// A Control-click: AppKit sends it as a left click.
        override func mouseDown(with event: NSEvent) {
            guard let menu = make?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
