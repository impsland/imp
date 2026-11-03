import CoreGraphics
import Testing
import ImpKit
@testable import Imp

/// The hidden Imp's sheet follows the Imp's own horns.
@MainActor @Suite struct HornTentsTests {
    @Test func hornsStandOnEitherSideOfTheHead() {
        let t = HornTents()
        #expect(t.left.tip.x < 50 && t.right.tip.x > 50)
        #expect(t.left.tip.y < t.left.outer.y)
        #expect(abs((t.left.tip.x + t.right.tip.x) / 2 - 50) < 0.5)
    }

    @Test func perkyHornsLeanInAndDroopyOnesLeanOut() {
        let perky = HornTents(traits: ImpTraits(horns: 30)), droopy = HornTents(traits: ImpTraits(horns: -30))
        #expect(perky.right.tip.x < droopy.right.tip.x)
        #expect(perky.left.tip.x > droopy.left.tip.x)
        #expect(perky.right.tip.y < droopy.right.tip.y)
    }

    @Test func differentHornsGiveDifferentSheets() {
        let rect = CGRect(x: 0, y: 0, width: 80, height: 78)
        let a = GhostSheet(phase: 0, tents: HornTents(traits: ImpTraits(horns: 30))).path(in: rect)
        let b = GhostSheet(phase: 0, tents: HornTents(traits: ImpTraits(horns: -30))).path(in: rect)
        #expect(a != b)
    }
}
