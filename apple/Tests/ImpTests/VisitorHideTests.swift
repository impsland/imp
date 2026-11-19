import AppKit
import Foundation
import Testing
import ImpKit
@testable import Imp

/// A visitor from another device can be hidden on its own, like an Imp of this Mac: it counts as hidden,
/// so Show is offered, Show brings it back, and its menu has Hide.
@MainActor @Suite struct VisitorHideTests {
    private func appWithVisitor() -> (AppModel, ImpModel) {
        _ = NSApplication.shared
        let app = AppModel(persist: false)
        let look = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
        app.welcome(Visiting(look: look, homeID: UUID(), homeName: "iPhone",
                             wakefulness: .visiting(homeConnected: true, homeSaysReady: true), side: .left, from: UUID()),
                    entry: nil)
        return (app, app.visitor(look.id)!)
    }

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
        // The menu is one card of buttons; Hide is one of its big buttons.
        #expect(menu.make().items.count == 1)
        #expect(menu.visitorButtons(pip.visit!).contains { $0.id == "hide" && $0.enabled })
    }
}

/// An Imp of this Mac away on a device that will never answer again (its app deleted) is never stuck:
/// the home window offers Call Home, which works without that device.
@MainActor @Suite struct CallHomeTests {
    @Test func theOnlyImpAwayOnAGoneDeviceCanBeCalledHome() {
        _ = NSApplication.shared
        let app = AppModel(persist: false)
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
}
