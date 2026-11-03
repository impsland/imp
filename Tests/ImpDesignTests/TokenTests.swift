import SwiftUI
import Testing
@testable import ImpDesign

@Suite("Design tokens")
struct TokenTests {
    @Test("Corner radii grow from small to bubble")
    func radiiAreAScale() {
        #expect(Radius.small < Radius.medium)
        #expect(Radius.medium < Radius.large)
        #expect(Radius.large < Radius.bubble)
    }

    @Test("Spacing grows from step to step")
    func spacingIsAScale() {
        let steps = [Spacing.hairline, Spacing.tight, Spacing.small, Spacing.medium, Spacing.large, Spacing.page, Spacing.huge]
        #expect(steps == steps.sorted())
        #expect(Set(steps).count == steps.count)
    }

    @Test("Hit targets meet the platform minimum")
    func hitTargets() {
        #if os(iOS)
        #expect(Sizing.hit >= 44)
        #else
        #expect(Sizing.hit >= 28)
        #endif
        #expect(Sizing.control >= Sizing.hit)
    }

    @Test("The short animation is shorter than the medium one")
    func timing() {
        #expect(Timing.short < Timing.medium)
    }

    @Test("The brick noise stays within 0 to 1 and is stable")
    func noiseIsStable() {
        for a in 0..<20 {
            for b in 0..<20 {
                let n = DungeonWall.noise(a, b)
                #expect(n >= 0 && n < 1)
                #expect(n == DungeonWall.noise(a, b))
            }
        }
    }
}
