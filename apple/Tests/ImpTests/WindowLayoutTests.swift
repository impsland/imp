import CoreGraphics
import ImpDesign
import ImpKit
import Testing
@testable import Imp

/// The smallest window (a fixed design value) against the narrow layout's breakpoint (a design token).
@Suite struct WindowLayoutTests {
    @Test func theSmallestWindowShowsTheNarrowLayout() {
        let smallest = WindowSizing.minimum.width
        #expect(smallest < CGFloat(Behavior.narrowWindowPoints))
        #expect(ImpSettingsLayout.mode(width: smallest, largeText: false, screenReader: false) == .list)
    }

    @Test func theStandardSizeShowsTheMarkers() {
        #expect(ImpSettingsLayout.mode(width: WindowSizing.size(of: .small, in: CGSize(width: 1440, height: 900)).width, largeText: false, screenReader: false) == .markers)
    }
}
