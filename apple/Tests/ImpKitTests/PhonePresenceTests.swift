import Foundation
import Testing
@testable import ImpKit

/// An Imp is in one place at a time: a sheet about one that is somewhere else closes.
@Suite("Phone sheets follow their Imp")
struct PhonePresenceTests {
    private let pip = UUID(), bo = UUID(), guest = UUID()

    @Test("A chat left open closes once another device has taken the Imp of this phone it was about")
    func takenByTheDesktop() {
        var router = PhoneRouter()
        router.talk(pip)
        let home = PhonePresence(room: [pip, bo], own: [pip, bo], away: [])
        // Thrown: in flight it is out of the room, but it may still land back here.
        let flying = PhonePresence(room: [bo], own: [pip, bo], away: [])
        router.roomChanged(from: home, to: flying)
        #expect(router.route == .imp(pip))
        // The Mac took it.
        let taken = PhonePresence(room: [bo], own: [pip, bo], away: [pip])
        router.roomChanged(from: flying, to: taken)
        #expect(router.route == nil)
    }

    @Test("A throw that is declined or times out keeps the chat")
    func declined() {
        var router = PhoneRouter()
        router.talk(pip)
        let home = PhonePresence(room: [pip], own: [pip], away: [])
        let flying = PhonePresence(room: [], own: [pip], away: [])
        router.roomChanged(from: home, to: flying)
        router.roomChanged(from: flying, to: home)
        #expect(router.route == .imp(pip))
    }

    @Test("Its settings, opened from its chat, close with it and Close doesn't lead back to it")
    func settingsToo() {
        var router = PhoneRouter()
        router.talk(pip)
        router.open(.edit(pip, brain: false))
        router.roomChanged(from: PhonePresence(room: [pip], own: [pip], away: []), to: PhonePresence(room: [], own: [pip], away: [pip]))
        #expect(router.route == nil)
    }

    @Test("A visitor that goes, and an Imp of this phone deleted, take their sheet; another Imp's sheet stays")
    func visitorsAndGoodbyes() {
        var router = PhoneRouter()
        router.talk(guest)
        router.roomChanged(from: PhonePresence(room: [pip, guest], own: [pip], away: []), to: PhonePresence(room: [pip], own: [pip], away: []))
        #expect(router.route == nil)
        router.talk(pip)
        router.roomChanged(from: PhonePresence(room: [pip, bo], own: [pip, bo], away: []), to: PhonePresence(room: [pip], own: [pip], away: []))
        #expect(router.route == .imp(pip))
        router.roomChanged(from: PhonePresence(room: [pip], own: [pip], away: []), to: PhonePresence(room: [], own: [], away: []))
        #expect(router.route == nil)
    }

    @Test("An Imp called back home is not a departure")
    func comingBack() {
        #expect(PhoneRouter.departed(from: PhonePresence(room: [], own: [pip], away: [pip]),
                                     to: PhonePresence(room: [pip], own: [pip], away: [])).isEmpty)
    }
}
