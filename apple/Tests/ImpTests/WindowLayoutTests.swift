import CoreGraphics
import ImpDesign
import ImpKit
import Testing
@testable import Imp

/// The smallest window (a fixed design value) against the narrow layout's breakpoint (a design token).
@Suite struct WindowLayoutTests {
    @Test func theSmallestWindowShowsTheCompactRail() {
        #expect(WindowSizing.minimum.width < CGFloat(Behavior.narrowWindowPoints))
    }

    @Test func theStandardSizeShowsTheRailWithTitles() {
        #expect(WindowSizing.size(of: .small, in: CGSize(width: 1440, height: 900)).width >= CGFloat(Behavior.narrowWindowPoints))
    }
}
