import Foundation
import Testing
@testable import ImpKit

@Suite("Stage labels")
struct StageLabelsTests {
    @Test("Words around an Imp are hidden while a game is on")
    func hiddenWhilePlaying() {
        let imp = UUID()
        #expect(StageLabels.showsWords(playing: false, menuFor: nil, imp: imp))
        #expect(!StageLabels.showsWords(playing: true, menuFor: nil, imp: imp))
    }

    @Test("A long press hides the words of that Imp only")
    func menuHidesOwnWords() {
        let a = UUID(), b = UUID()
        #expect(!StageLabels.showsWords(playing: false, menuFor: a, imp: a))
        #expect(StageLabels.showsWords(playing: false, menuFor: a, imp: b))
    }
}
