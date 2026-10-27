import CoreGraphics
import Testing
@testable import ImpKit

@Suite struct ReadAllCutTests {
    typealias Span = ReadAllCut.Span

    @Test func cutClearOfPicturesStaysPut() {
        let spans = [Span(top: 300, bottom: 500)]
        #expect(ReadAllCut.limit(textHeight: 800, spans: spans, cap: 210, most: 600) == 210)
        #expect(ReadAllCut.limit(textHeight: 800, spans: [], cap: 210, most: 600) == 210)
    }

    @Test func cutInsideAPictureShowsItsBottom() {
        let spans = [Span(top: 120, bottom: 360)]
        #expect(ReadAllCut.limit(textHeight: 900, spans: spans, cap: 210, most: 600) == 360)
    }

    @Test func pictureTooLowMovesTheCutAboveIt() {
        let spans = [Span(top: 150, bottom: 390)]
        #expect(ReadAllCut.limit(textHeight: 900, spans: spans, cap: 210, most: 300) == 150)
    }

    @Test func littleBelowThePictureShowsEverything() {
        let spans = [Span(top: 100, bottom: 340)]
        #expect(ReadAllCut.limit(textHeight: 380, spans: spans, cap: 210, most: 600) == nil)
        // ...but only if it all fits
        #expect(ReadAllCut.limit(textHeight: 380, spans: spans, cap: 210, most: 350) == 340)
    }

    @Test func tallPicturesBehaveAsBefore() {
        let spans = [Span(top: 20, bottom: 700)]
        #expect(ReadAllCut.limit(textHeight: 900, spans: spans, cap: 210, most: 500) == 210)
    }

    @Test func nothingWorthKeepingAboveThePictureCutsAsBefore() {
        let spans = [Span(top: 10, bottom: 400)]
        #expect(ReadAllCut.limit(textHeight: 900, spans: spans, cap: 210, most: 300) == 210)
    }
}
