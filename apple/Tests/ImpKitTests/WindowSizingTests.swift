import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// The home window's smallest size is a setting; the narrow layout's breakpoint is a design token.
@Suite struct WindowSizingTests {
    @Test func theDefaultIsDocumentedAndStoredAsNothing() throws {
        var prefs = ImpPreferences()
        #expect(prefs.windowMinimum == WindowSizing.defaultMinimum)
        prefs.windowMinimum = CGSize(width: 500, height: 460)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.windowMinimum == CGSize(width: 500, height: 460))
        prefs.windowMinimum = WindowSizing.defaultMinimum
        let json = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self)
        #expect(!json.contains("windowMinWidth"), "the default is not written")
    }

    @Test func theSettingStaysWithinItsBounds() {
        var prefs = ImpPreferences()
        prefs.windowMinimum = CGSize(width: 10, height: 10_000)
        #expect(prefs.windowMinimum == CGSize(width: WindowSizing.widths.lowerBound, height: WindowSizing.heights.upperBound))
        #expect(WindowSizing.clamped(CGSize(width: CGFloat.nan, height: .infinity)).width == WindowSizing.defaultMinimum.width)
        #expect(WindowSizing.widths.contains(Double(WindowSizing.defaultMinimum.width)))
        #expect(WindowSizing.heights.contains(Double(WindowSizing.defaultMinimum.height)))
    }

    @Test func theWindowFirstOpensAtLeastAsLargeAsTheMinimum() {
        #expect(WindowSizing.opening(minimum: WindowSizing.defaultMinimum) == WindowSizing.firstOpen)
        #expect(WindowSizing.opening(minimum: CGSize(width: 1000, height: 500)) == CGSize(width: 1000, height: WindowSizing.firstOpen.height))
    }

    @Test func aLargerMinimumGrowsTheWindowAndASmallerOneLeavesIt() {
        let current = CGSize(width: 700, height: 500)
        #expect(WindowSizing.fitted(current, minimum: CGSize(width: 800, height: 450)) == CGSize(width: 800, height: 500))
        #expect(WindowSizing.fitted(current, minimum: CGSize(width: 400, height: 420)) == current)
    }
}
