import Foundation
import Testing
@testable import ImpKit

@Suite struct ImpMovesTests {
    // MARK: Drag out and drag back

    private let arena = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func figure(centre: CGPoint, side: CGFloat = 112) -> CGRect {
        CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    @Test func anImpInTheWindowStaysWhileItsFrameIsWhollyInside() {
        #expect(ImpDrag.whileDragging(isFree: false, figure: figure(centre: CGPoint(x: 500, y: 400)), arena: arena) == .stay)
        // Touching the edge is still inside.
        #expect(ImpDrag.whileDragging(isFree: false, figure: figure(centre: CGPoint(x: 156, y: 400)), arena: arena) == .stay)
    }

    @Test func anImpIsLetOutAsSoonAsItsFrameCrossesAnEdgeEvenWithThePointerInside() {
        // The pointer holds the Imp by its edge: the pointer is inside, the frame is not.
        let centre = CGPoint(x: 150, y: 400)
        let pointer = CGPoint(x: 120, y: 400)
        #expect(arena.contains(pointer))
        #expect(ImpDrag.whileDragging(isFree: false, figure: figure(centre: centre), arena: arena) == .letOut)
        for centre in [CGPoint(x: 850, y: 400), CGPoint(x: 500, y: 140), CGPoint(x: 500, y: 660), CGPoint(x: 0, y: 0)] {
            #expect(ImpDrag.whileDragging(isFree: false, figure: figure(centre: centre), arena: arena) == .letOut)
        }
    }

    @Test func aFreeImpKeepsGoingWhileDragged() {
        #expect(ImpDrag.whileDragging(isFree: true, figure: figure(centre: CGPoint(x: 500, y: 400)), arena: arena) == .stay)
        #expect(ImpDrag.whileDragging(isFree: true, figure: figure(centre: CGPoint(x: 0, y: 0)), arena: arena) == .stay)
    }

    @Test func theGrabIsKeptExactlyAcrossTheHandOff() {
        let centre = CGPoint(x: 150, y: 400), pointer = CGPoint(x: 131, y: 423)
        let grab = ImpDrag.grab(pointer: pointer, centre: centre)
        #expect(grab == CGSize(width: -19, height: 23))
        // The panel is placed at the Imp's drawn frame...
        let origin = ImpDrag.origin(pointer: pointer, grab: grab, side: 112)
        #expect(origin == figure(centre: centre).origin)
        // ...and follows the pointer with the same grab, however far it travels.
        let moved = CGPoint(x: pointer.x - 300, y: pointer.y + 40)
        let next = ImpDrag.origin(pointer: moved, grab: grab, side: 112)
        #expect(CGPoint(x: next.x + 56, y: next.y + 56) == CGPoint(x: moved.x - grab.width, y: moved.y - grab.height))
    }

    @Test func aFreeImpDroppedOnTheWindowGoesHome() {
        #expect(ImpDrag.onDrop(isFree: true, pointerInWindow: true) == .sendHome)
        #expect(ImpDrag.onDrop(isFree: true, pointerInWindow: false) == .stay)
        #expect(ImpDrag.onDrop(isFree: false, pointerInWindow: true) == .stay)
    }

    // MARK: The Undo bar

    @Test func anUndoOfferLastsForTheGivenSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let offer = UndoOffer(.letOut, imp: UUID(), seconds: 6, at: start)
        #expect(offer.isOpen(at: start.addingTimeInterval(5.9)))
        #expect(!offer.isOpen(at: start.addingTimeInterval(6)))
        #expect(!offer.isOpen(at: start.addingTimeInterval(-1)))
    }

    // MARK: Peeking

    private let plan = PeekPlan(minSeconds: 45, maxSeconds: 90, showSeconds: 1.5, quietSeconds: 10)

    @Test func theWaitIsBetweenTheLimits() {
        #expect(plan.wait(unit: 0) == 45)
        #expect(plan.wait(unit: 1) == 90)
        #expect(plan.wait(unit: 0.5) == 67.5)
        #expect(plan.wait(unit: 7) == 90)
        #expect(plan.wait(unit: -3) == 45)
    }

    @Test func itPeeksOnlyWhenTheWindowIsSeenAndTheUserIsQuiet() {
        #expect(plan.mayPeek(windowVisible: true, secondsSinceTyping: 10, peeking: false, hidden: 1))
        #expect(!plan.mayPeek(windowVisible: false, secondsSinceTyping: 60, peeking: false, hidden: 1))
        #expect(!plan.mayPeek(windowVisible: true, secondsSinceTyping: 9.9, peeking: false, hidden: 1))
        #expect(!plan.mayPeek(windowVisible: true, secondsSinceTyping: 60, peeking: true, hidden: 2))
        #expect(!plan.mayPeek(windowVisible: true, secondsSinceTyping: 60, peeking: false, hidden: 0))
    }

    @Test func oneImpPeeksAtATimeAndTheyTakeTurns() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(plan.pick(from: [], after: nil) == nil)
        #expect(plan.pick(from: [a], after: a) == a)
        #expect(plan.pick(from: [a, b, c], after: nil) == a)
        #expect(plan.pick(from: [a, b, c], after: a) == b)
        #expect(plan.pick(from: [a, b, c], after: c) == a)
        #expect(plan.pick(from: [a, c], after: b) == a)
    }

    // MARK: Clicks

    @Test func aSecondClickIsOnlyWaitedForWhenATriggerNeedsIt() {
        var p = ImpPreferences.withWaitingImp()
        let imp = p.imps[0].id
        #expect(!p.waitsForMoreClicks(on: imp), "no triggers: a click opens the bubble at once")
        p.shortcuts = [Shortcut(name: "Chat", trigger: .click(1), steps: [Step(.open, value: "chat")])]
        #expect(!p.waitsForMoreClicks(on: imp), "one click alone needs no second")
        p.shortcuts[0].trigger = .click(2)
        #expect(p.waitsForMoreClicks(on: imp))
        p.shortcuts[0].isEnabled = false
        #expect(!p.waitsForMoreClicks(on: imp), "a switched-off trigger waits for nothing")
    }

    @Test func aFreshInstallAnswersToNoClicksAndNewImpsShareASharedOne() {
        var p = ImpPreferences.withWaitingImp()
        #expect(!p.waitsForMoreClicks(on: p.imps[0].id))
        p.shortcuts = [Shortcut(name: "Settings", trigger: .click(2), steps: [Step(.open, value: "settings")])]
        #expect(p.waitsForMoreClicks(on: p.imps[0].id))
        let newcomer = ImpProfile(name: "Newcomer", hue: 0.3, favoriteHue: 0.3, personality: "")
        p.imps.append(newcomer)
        #expect(p.clickShortcut(2, on: newcomer.id, in: nil)?.steps.first?.target == .settings)
    }

    // MARK: Hidden on the phone

    @Test func aHiddenImpLeavesTheStageAndComesBack() {
        let a = UUID(), b = UUID()
        var hidden = HiddenImps()
        hidden.hide(a)
        hidden.hide(a)
        hidden.hide(b)
        #expect(hidden.ids == [a, b])
        #expect(hidden.contains(a))
        hidden.bringBack(a)
        #expect(!hidden.contains(a))
        #expect(hidden.ids == [b])
        hidden.bringBackAll()
        #expect(hidden.ids.isEmpty)
    }

    @Test func theStageAndTheFloorSplitTheRosterInItsOwnOrder() {
        let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
        var hidden = HiddenImps()
        hidden.hide(c)
        hidden.hide(gone)
        hidden.hide(a)
        #expect(hidden.standing(in: [a, b, c]) == [b])
        #expect(hidden.onFloor(in: [a, b, c]) == [a, c])
    }

    @Test func theHiddenOnesAreSavedAndForgottenWhenTheyLeaveTheRoster() throws {
        let a = UUID(), b = UUID()
        var hidden = HiddenImps()
        hidden.hide(a)
        hidden.hide(b)
        let back = try JSONDecoder().decode(HiddenImps.self, from: JSONEncoder().encode(hidden))
        #expect(back == hidden)
        hidden.forget(except: [b])
        #expect(hidden.ids == [b])
    }
}
