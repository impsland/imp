import CoreGraphics
import ImpDesign
import ImpKit
import Testing
@testable import Imp

/// The smallest window (a setting) against the narrow layout's breakpoint (a design token).
@Suite struct WindowLayoutTests {
    @Test func theSmallestWindowTheSettingAllowsShowsTheNarrowLayout() {
        let smallest = CGFloat(WindowSizing.widths.lowerBound)
        #expect(smallest < CGFloat(Behavior.narrowWindowPoints))
        #expect(ImpSettingsLayout.mode(width: smallest, largeText: false, screenReader: false) == .list)
    }

    @Test func theDefaultMinimumShowsTheMarkers() {
        #expect(ImpSettingsLayout.mode(width: WindowSizing.defaultMinimum.width, largeText: false, screenReader: false) == .markers)
    }
}
