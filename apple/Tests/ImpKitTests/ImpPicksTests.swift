import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

@Suite struct ImpPicksTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func theFirstCommandClickAddsToTheChosenImp() {
        #expect(ImpPicks.toggle(b, in: [], selection: a) == [a, b])
        #expect(ImpPicks.toggle(b, in: [], selection: nil) == [b])
    }

    @Test func aCommandClickOnAPickedImpTakesItOut() {
        #expect(ImpPicks.toggle(b, in: [a, b], selection: a) == [a])
    }

    @Test func aMenuActsOnTheGroupOnlyWhenOpenedOnOneOfIt() {
        #expect(ImpPicks.group(of: b, picked: [c, b], order: [a, b, c]) == [b, c])
        #expect(ImpPicks.group(of: a, picked: [c, b], order: [a, b, c]) == [a])
        #expect(ImpPicks.group(of: a, picked: [a], order: [a, b, c]) == [a])
    }

    @Test func aBoxPicksTheImpsWhoseMiddleIsInside() {
        let box = ImpPicks.box(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 0, y: 0))
        #expect(box == CGRect(x: 0, y: 0, width: 100, height: 100))
        let centres = [a: CGPoint(x: 50, y: 50), b: CGPoint(x: 150, y: 50), c: CGPoint(x: 99, y: 1)]
        #expect(ImpPicks.inside(box, centres: centres) == [a, c])
    }

    @Test func oneImpAlwaysStays() {
        #expect(ImpPicks.canSayGoodbye(to: 2, of: 3))
        #expect(ImpPicks.canSayGoodbye(to: 3, of: 3), "every Imp may go: having none is fine")
        #expect(!ImpPicks.canSayGoodbye(to: 4, of: 3))
        #expect(!ImpPicks.canSayGoodbye(to: 0, of: 3))
    }
}
