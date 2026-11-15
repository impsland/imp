import Foundation
import Testing
@testable import ImpKit

@Suite("Phone router")
struct PhoneRouterTests {
    private let a = UUID(), b = UUID()
    private let here: (UUID) -> Bool = { _ in true }

    @Test("The room has no sheet at first")
    func startsInTheRoom() {
        #expect(PhoneRouter().route == nil)
    }

    @Test("Talk opens the Imp's sheet on its chat; the talks side is chosen from inside it")
    func talkAndTalks() {
        var router = PhoneRouter()
        router.talk(a); router.pane = .talks
        #expect(router.route == .imp(a))
        #expect(router.pane == .talks)
        router.talk(a)
        #expect(router.route == .imp(a))
        #expect(router.pane == .chat)
    }

    @Test("Another Imp's sheet always opens on its chat")
    func anotherImpStartsOnChat() {
        var router = PhoneRouter()
        router.talk(a); router.pane = .talks
        router.open(.imp(b))
        #expect(router.route == .imp(b))
        #expect(router.pane == .chat)
    }

    @Test("Close on settings opened from the Imp's sheet goes back to that sheet, on the side it was")
    func closeReturnsToTheImp() {
        var router = PhoneRouter()
        router.talk(a); router.pane = .talks
        router.open(.edit(a, brain: false))
        #expect(router.route == .edit(a, brain: false))
        router.close(exists: here)
        #expect(router.route == .imp(a))
        #expect(router.pane == .talks)
        router.close(exists: here)
        #expect(router.route == nil)
    }

    @Test("Close on settings opened from the room goes back to the room")
    func closeReturnsToTheRoom() {
        var router = PhoneRouter()
        router.open(.edit(a, brain: false))
        router.close(exists: here)
        #expect(router.route == nil)
    }

    @Test("Settings that move to the Brain keep the way back")
    func brainKeepsTheWayBack() {
        var router = PhoneRouter()
        router.talk(a)
        router.open(.edit(a, brain: false))
        router.open(.edit(a, brain: true))
        router.close(exists: here)
        #expect(router.route == .imp(a))
    }

    @Test("An Imp that said goodbye in its settings is not returned to")
    func goodbyeReturnsToTheRoom() {
        var router = PhoneRouter()
        router.talk(a)
        router.open(.edit(a, brain: false))
        router.close(exists: { _ in false })
        #expect(router.route == nil)
    }

    @Test("Settings of one Imp opened from another Imp's sheet do not return to it")
    func otherImpIsNotAnOrigin() {
        var router = PhoneRouter()
        router.talk(a)
        router.open(.edit(b, brain: false))
        router.close(exists: here)
        #expect(router.route == nil)
    }

    @Test("A sheet swiped away goes to the room, wherever it came from")
    func swipedAway() {
        var router = PhoneRouter()
        router.talk(a)
        router.open(.edit(a, brain: true))
        router.dismissed()
        #expect(router.route == nil)
        router.open(.edit(a, brain: false))
        router.close(exists: here)
        #expect(router.route == nil)
    }

    @Test("Waking an Imp ends in its chat")
    func wokeOpensChat() {
        var router = PhoneRouter()
        router.open(.firstRun(a))
        router.woke(a)
        #expect(router.route == .imp(a))
        #expect(router.pane == .chat)
        router.close(exists: here)
        #expect(router.route == nil)
    }

    @Test("A sheet about an Imp that left closes, and nothing returns to it")
    func impLeft() {
        var router = PhoneRouter()
        router.talk(a)
        router.left(a)
        #expect(router.route == nil)

        router.talk(a)
        router.open(.edit(a, brain: false))
        router.left(b)
        #expect(router.route == .edit(a, brain: false))
        router.left(a)
        #expect(router.route == nil)

        router.open(.settings(devices: true))
        router.left(a)
        #expect(router.route == .settings(devices: true))
    }

    @Test("Going from one Imp to another keeps the same sheet; any other step is a new sheet")
    func sheetIdentity() {
        #expect(PhoneRoute.imp(a).id == PhoneRoute.imp(b).id)
        #expect(PhoneRoute.imp(a).id != PhoneRoute.edit(a, brain: false).id)
        #expect(PhoneRoute.edit(a, brain: false).id != PhoneRoute.edit(b, brain: false).id)
        #expect(PhoneRoute.settings(devices: true).id != PhoneRoute.firstRun(a).id)
    }

    @Test("An Imp's sheet, the settings and an Imp's settings rest at half height")
    func halfHeight() {
        #expect(PhoneRoute.imp(a).restsAtHalf)
        #expect(PhoneRoute.settings(devices: false).restsAtHalf)
        #expect(PhoneRoute.edit(a, brain: false).restsAtHalf)
        #expect(!PhoneRoute.firstRun(a).restsAtHalf)
    }

    @Test("A sheet knows the Imp it is about")
    func impOfARoute() {
        #expect(PhoneRoute.imp(a).imp == a)
        #expect(PhoneRoute.edit(a, brain: true).imp == a)
        #expect(PhoneRoute.firstRun(a).imp == a)
        #expect(PhoneRoute.settings(devices: true).imp == nil)
    }
}

@Suite("Summon")
struct SummonTests {
    private let room = CGSize(width: 400, height: 800)

    @Test("With no sheet nobody is called anywhere")
    func noSheet() {
        #expect(Summon.point(room: room, top: 50, cover: 0, side: 100, height: 0.6) == nil)
    }

    @Test("Above a half sheet the Imp waits in the middle of the free room, a little below its centre")
    func halfSheet() {
        let point = Summon.point(room: room, top: 50, cover: 0.5, side: 100, height: 0.6)
        #expect(point == CGPoint(x: 200, y: 50 + 350 * 0.6))
    }

    @Test("A sheet over the whole screen leaves the Imp where it is")
    func fullSheet() {
        #expect(Summon.point(room: room, top: 50, cover: 1, side: 100, height: 0.6) == nil)
    }

    @Test("Too little free room for the Imp and its bubble leaves it where it is")
    func tooLittleRoom() {
        #expect(Summon.point(room: room, top: 50, cover: 0.8, side: 100, height: 0.6) == nil)
    }

    @Test("The Imp is never put under the sheet or over the top of the screen")
    func staysInTheFreeRoom() {
        let low = Summon.point(room: room, top: 50, cover: 0.5, side: 100, height: 1)
        #expect(low?.y == 350)
        let high = Summon.point(room: room, top: 50, cover: 0.5, side: 100, height: 0)
        #expect(high?.y == 100)
    }
}
