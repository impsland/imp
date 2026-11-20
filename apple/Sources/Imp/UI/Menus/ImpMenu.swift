import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The menu you get by right-clicking an Imp on the desktop: everything about *that* Imp and nothing else.
/// (App-wide things live in the menu bar menu.) It is one card of buttons (`MenuCard`): the top is
/// `ImpMenuCard`, the same as in the app's window and for a visitor, and what only sometimes applies sits under it
/// as pills, in this order: Stop and Copy last reply, triggers, devices to visit, Copy kit and Copy link, and
/// Goodbye last and apart. Only the place button differs from the window's menu (Send home here, Let out there).
@MainActor
final class ImpMenu {
    private let app: AppModel
    private let imp: ImpModel
    /// Holds the menu's actions until it has closed (the menu's own targets are weak).
    private let card = CardMenu()

    init(app: AppModel, imp: ImpModel) {
        self.app = app
        self.imp = imp
    }

    func make() -> NSMenu {
        if let visit = imp.visit { return card.make(visitorCard(visit)) }
        let status = imp.isReady ? String(localized: "Awake") : String(localized: "Needs a brain")
        let actions = HomeActions(model: app, router: HomeWindow.shared.router)
        let id = imp.id
        return card.make(ImpMenuCard(ready: imp.isReady, name: imp.profile.name, status: status, hue: imp.profile.hue,
                                     scale: imp.profile.scale, place: .desktop) { [weak self] action in
            self?.run(action)
        } extra: {
            extras
            ImpMenuEnd(canLink: actions.canShareLink(id), canGoodbye: actions.canSayGoodbye,
                       kit: { [card] in card.later { actions.copyKit(id) } },
                       link: { [card] in card.later { actions.copyLink(id) } },
                       goodbye: { [app, card] in
                           card.later {
                               actions.askGoodbye([id])
                               HomeWindow.shared.show(app, imp: id)        // the window asks the question
                           }
                       })
        })
    }

    private func run(_ action: ImpMenuAction) {
        let imp = imp
        switch action {
        case .talk: card.later { imp.talk() }
        case .message: card.later { imp.startTyping() }
        case .chat: card.later { imp.openChat() }
        case .newChat: card.later { imp.startNewChat() }
        case .hide: card.later { [app] in app.setHidden(imp.id, true) }
        case .move: card.later { [app] in Self.sendHome(imp.id, app: app) }
        case .settings: card.later { imp.openSettings() }
        case .size(let scale): set { $0.scale = scale }
        case .colour(let hue): set { $0.hue = hue }
        }
    }

    /// Stop and Copy while there is something to stop or copy, the triggers that ask it something, and the
    /// devices it can visit.
    @ViewBuilder private var extras: some View {
        let now = rightNow
        if !now.isEmpty { MenuPills(items: now) }
        let own = triggers
        if !own.isEmpty { MenuPills(title: String(localized: "Triggers"), items: own) }
        if app.link.isLinked { MenuPills(title: String(localized: "menu.imp.visit"), items: visits(doors: nil)) }
    }

    private var rightNow: [MenuItem] {
        var items: [MenuItem] = []
        let imp = imp
        if imp.isBusy {
            items.append(MenuItem(id: "stop", icon: "stop.circle", title: String(localized: "Stop")) { [card] in card.later { imp.dismissBubble() } })
        }
        if imp.bubble?.phase == .result {
            items.append(MenuItem(id: "copy", icon: "doc.on.doc", title: String(localized: "Copy Last Reply")) { [card] in
                card.later { imp.copyBubble() }
            })
        }
        return items
    }

    /// Its own triggers that ask it something, to run right now (clicks are right here already).
    private var triggers: [MenuItem] {
        let imp = imp
        return app.prefs.triggers(for: imp.id).filter { $0.isEnabled && $0.askStep != nil && $0.trigger.event != .click }.map { action in
            MenuItem(id: action.id.uuidString, icon: action.trigger.event == .keys ? action.symbol : action.trigger.event.symbol,
                     title: action.name) { [app, card] in
                card.later { app.trigger(action, on: imp, trying: true) }
            }
        }
    }

    /// One pill per linked device it can go to (`doors`: only these, for a visitor), or a dimmed one while none is around.
    private func visits(doors: Set<UUID>?) -> [MenuItem] {
        let imp = imp
        let name = imp.visit?.look.name ?? imp.profile.name
        let around = app.link.connectedPeers.filter { doors?.contains($0.id) ?? true }
        guard !around.isEmpty else {
            guard doors == nil else { return [] }
            return [MenuItem(id: "none", icon: "iphone.gen3", title: String(localized: "menu.imp.visit_none"),
                             help: String(localized: "Open Imp on a linked device first (same network as this Mac, or the same server)."),
                             enabled: false) {}]
        }
        return around.map { peer in
            MenuItem(id: peer.id.uuidString, icon: peer.kind == .mac ? "desktopcomputer" : "iphone.gen3", title: peer.name,
                     help: words("menu.imp.visit_tip", name, peer.name)) { [app, card] in
                card.later { app.send(imp.id, to: peer.id) }
            }
        }
    }

    /// A visiting Imp's menu: the same card as an own Imp's (its brain is at its home, so New chat takes the place of
    /// Settings, and there is no size, colour, trigger, sharing or Goodbye), then the devices it may go on to.
    private func visitorCard(_ visit: Visiting) -> some View {
        let imp = imp
        let name = visit.look.name
        let status = visit.isAwake ? String(localized: "\(name), visiting from \(visit.homeName)")
                                   : String(localized: "\(name) is asleep: \(visit.homeName) is away")
        let doors = Set([LinkSide.left, .right].flatMap { app.link.bands(of: imp.id, side: $0).map(\.device) })
        let visits = visits(doors: doors)
        let now = rightNow
        return ImpMenuCard(ready: visit.isAwake, name: name, status: status, hue: visit.look.hue, scale: 1,
                           place: .visitor(from: visit.homeName), awake: visit.isAwake) { [app, card] action in
            switch action {
            case .talk: card.later { imp.talk() }
            case .message: card.later { imp.startTyping() }
            case .chat: card.later { imp.openChat() }
            case .newChat: card.later { imp.startNewChat() }
            case .hide: card.later { app.setHidden(imp.id, true) }
            case .move: card.later { app.sendHome(visitor: imp.id) }
            case .settings, .size, .colour: break
            }
        } extra: {
            if !now.isEmpty { MenuPills(items: now) }
            if !visits.isEmpty { MenuPills(title: String(localized: "menu.imp.visit"), items: visits) }
        }
    }

    /// Size and colour change while the menu stays open, so both can be picked in one go.
    private func set(_ change: (inout ImpProfile) -> Void) {
        guard let i = app.prefs.imps.firstIndex(where: { $0.id == imp.id }) else { return }
        change(&app.prefs.imps[i])
    }

    /// Back into the app's window: flies home if the window is open, else just steps inside. Undo is in the window.
    private static func sendHome(_ id: UUID, app: AppModel) {
        let home = HomeWindow.shared
        HomeActions(model: app, router: home.router).toggleActive(id)
        if !home.isVisible { home.show(app, imp: id) }
    }
}
