import ImpDesign
import ImpKit
import Testing

/// ImpKit cannot see the tokens, so its copy of the bubble's opacity range is checked here.
@Suite struct BubbleAppearanceTokensTests {
    @Test func rangeMatchesTheTokens() {
        #expect(BubbleAppearance.minimumOpacity == Opacity.bubbleMin)
        #expect(BubbleAppearance.defaultOpacity == Opacity.bubbleDefault)
    }
}
