import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// The home window has a fixed smallest size and a few standard sizes to choose from.
@Suite struct WindowSizingTests {
    private let screen = CGSize(width: 1440, height: 900)

    @Test func theChosenSizeIsStoredAndTheDefaultIsNot() throws {
        var prefs = ImpPreferences()
        #expect(prefs.windowPreset == WindowSizing.standard)
        prefs.windowPreset = .large
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.windowPreset == .large)
    }

    @Test func presetsGrowInOrderAndFullIsTheScreen() {
        let small = WindowSizing.size(of: .small, in: screen)
        let medium = WindowSizing.size(of: .medium, in: screen)
        let large = WindowSizing.size(of: .large, in: screen)
        #expect(small.width < medium.width && medium.width < large.width)
        #expect(small.height < medium.height && medium.height < large.height)
        #expect(WindowSizing.size(of: .full, in: screen) == screen)
    }

    @Test func everyPresetFitsTheScreenAndStaysAboveTheMinimum() {
        let tiny = CGSize(width: 900, height: 600)
        for preset in WindowPreset.allCases {
            for visible in [screen, tiny] {
                let size = WindowSizing.size(of: preset, in: visible)
                #expect(size.width <= visible.width && size.height <= visible.height)
                #expect(size.width >= WindowSizing.minimum.width && size.height >= WindowSizing.minimum.height)
            }
        }
        #expect(WindowSizing.size(of: .large, in: tiny) == tiny)
    }

    @Test func theNewFrameKeepsTheTopLeftAndStaysOnTheScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let current = CGRect(x: 100, y: 300, width: 560, height: 520)
        let grown = WindowSizing.frame(for: .medium, from: current, in: visible)
        #expect(grown.minX == 100 && grown.maxY == 820)
        // Too near the right and bottom edges: it moves in, never off the screen.
        let edge = WindowSizing.frame(for: .large, from: CGRect(x: 1300, y: 30, width: 560, height: 200), in: visible)
        #expect(visible.contains(edge))
        #expect(visible.contains(WindowSizing.frame(for: .full, from: current, in: visible)))
        #expect(WindowSizing.frame(for: .full, from: current, in: visible) == visible)
    }
}
