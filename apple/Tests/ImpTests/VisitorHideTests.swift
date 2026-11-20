import AppKit
import Foundation
import Testing
import ImpKit
@testable import Imp

@MainActor private func appWithVisitor() -> (AppModel, ImpModel) {
    _ = NSApplication.shared
    let app = AppModel(persist: false)
    app.prefs.imps = [.waiting]
    let look = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
    app.welcome(Visiting(look: look, homeID: UUID(), homeName: "iPhone",
                         wakefulness: .visiting(homeConnected: true, homeSaysReady: true), side: .left, from: UUID()),
                entry: nil)
    return (app, app.visitor(look.id)!)
}

/// A visitor from another device can be hidden on its own, like an Imp of this Mac: it counts as hidden,
/// so Show is offered, Show brings it back, and its menu has Hide.
@MainActor @Suite struct VisitorHideTests {
    @Test func aHiddenVisitorCountsAndShowBringsItBack() {
        let (app, pip) = appWithVisitor()
        #expect(app.hiddenCount == 0)
        app.setHidden(pip.id, true)
        #expect(app.isHiding(pip.id))
        #expect(app.hiddenCount == 1)
        #expect(app.anyHiding)
        app.setHidden(false)
        #expect(!app.isHiding(pip.id))
        #expect(app.hiddenCount == 0)
    }

    @Test func aVisitorsMenuOffersHide() {
        let (app, pip) = appWithVisitor()
        let menu = ImpMenu(app: app, imp: pip)
        // The menu is one card of buttons. Hide is one of its big buttons.
        #expect(menu.make().items.count == 1)
        // Same six buttons as an own Imp's menu, with New chat for Settings. Asleep, only what needs no brain stays.
        let awake = ImpMenuCard(ready: true, name: "Pip", status: "", hue: 0.3, scale: 1, place: .visitor(from: "iPhone")) { _ in }
        #expect(awake.buttons.map(\.id) == ["talk", "message", "chat", "hide", "move", "new"])
        #expect(awake.buttons.allSatisfy { $0.enabled })
        let asleep = ImpMenuCard(ready: false, name: "Pip", status: "", hue: 0.3, scale: 1, place: .visitor(from: "iPhone"), awake: false) { _ in }
        #expect(asleep.buttons.filter(\.enabled).map(\.id) == ["chat", "hide", "move"])
    }
}

/// An Imp of this Mac away on a device that will never answer again (its app deleted) is never stuck:
/// the home window offers Call Home, which works without that device.
@MainActor @Suite struct CallHomeTests {
    @Test func theOnlyImpAwayOnAGoneDeviceCanBeCalledHome() {
        _ = NSApplication.shared
        let app = AppModel(persist: false)
        app.prefs.imps = [.waiting]
        let id = app.prefs.imps[0].id
        app.setActive(id, true)
        app.held(id, by: UUID())
        #expect(app.isAway(id))
        let actions = HomeActions(model: app, router: HomeRouter())
        #expect(actions.canRelease(id))
        #expect(actions.releaseTitle(id) == String(localized: "menu.imp.call_home_ask"))
        app.callHome(id)
        #expect(!app.isAway(id))
        #expect(app.prefs.imps[0].isActive)
    }

    @Test func aVisitorMirrorsItsHomesChatsAndSwitchingWaitsForTheHome() {
        let (app, pip) = appWithVisitor()
        defer { withExtendedLifetime(app) {} }                                                  // the visitor holds its app unowned
        let now = LinkTurn(id: UUID(), date: Date(), request: "now", from: nil, reply: "ok", failed: false)
        let first = LinkChat(id: UUID(), title: "Earlier", updated: Date(timeIntervalSince1970: 10))
        let second = LinkChat(id: UUID(), title: "Now", updated: Date(timeIntervalSince1970: 20))
        pip.heard(chat: [now])
        pip.heard(chats: [second, first], current: second.id)
        #expect(pip.history.chats.map(\.title) == ["Now", "Earlier"])
        #expect(pip.history.current.id == second.id)
        #expect(pip.history.turns.map(\.request) == ["now"])
        // The turns of a later `chat` keep the list.
        pip.heard(chat: [])
        #expect(pip.history.chats.count == 2 && pip.history.current.id == second.id && pip.history.turns.isEmpty)
        // Picking the other chat asks the home: what is shown stays until the home says.
        pip.switchChat(to: first.id)
        #expect(pip.history.current.id == second.id)
        pip.heard(chat: [now])
        pip.heard(chats: [second, first], current: first.id)
        #expect(pip.history.current.id == first.id && pip.history.current.title == "Earlier")
    }

    @Test func anAsleepVisitorCannotStartOrSwitchChats() {
        let (app, pip) = appWithVisitor()
        let other = LinkChat(id: UUID(), title: "Other", updated: Date())
        pip.heard(chats: [other], current: UUID())
        let before = pip.history.current.id
        var asleep = pip.visit!
        asleep.wakefulness = .visiting(homeConnected: false, homeSaysReady: true)
        pip.update(asleep)
        #expect(pip.newChat() == false)
        pip.switchChat(to: other.id)
        #expect(pip.history.current.id == before)
        withExtendedLifetime(app) {}
    }
}
