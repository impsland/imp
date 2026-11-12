import ImpKit
import Testing
@testable import Imp

/// The Background choice offers every kind, and only Colour, Picture and Tile ask for a follow-up action.
@Suite struct BackgroundGroupTests {
    @Test func everyKindHasASymbolAndTitle() {
        #expect(BackgroundGroup.kinds.count == 4)
        for kind in BackgroundGroup.kinds {
            #expect(!BackgroundGroup.symbol(kind).isEmpty)
            #expect(!BackgroundGroup.title(kind).isEmpty)
        }
    }

    @Test func followUpOnlyWhenRelevant() {
        #expect(BackgroundGroup.follow(.theme) == nil)
        #expect(BackgroundGroup.follow(.colour) == .colour)
        #expect(BackgroundGroup.follow(.picture) == .picture)
        #expect(BackgroundGroup.follow(.tile) == .picture)
    }
}
