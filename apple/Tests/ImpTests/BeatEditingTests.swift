import Foundation
import Testing
import ImpKit
@testable import Imp

/// The rules behind the animation editor's timeline: editing the list of beats, the undo steps,
/// and the track's time-to-position math.
@Suite struct BeatEditingTests {
    private func beats(_ durations: Double...) -> [AnimationBeat] { durations.map { AnimationBeat(duration: $0) } }

    @Test func addPutsACleanCopyAfterThePickedBeat() {
        var first = AnimationBeat(duration: 0.4, mood: "happy", hop: true)
        first.glyph = "heart"; first.move = "spin"; first.times = 2; first.reverse = true
        var list = BeatList(beats: [first, AnimationBeat(duration: 1)], selected: 0)
        list.add()
        #expect(list.beats.count == 3)
        #expect(list.selected == 1)
        let added = list.beats[1]
        #expect(added.duration == 0.4 && added.mood == "happy")
        #expect(!added.hop && added.glyph == nil && added.move == nil && added.times == nil && added.reverse == nil)
    }

    @Test func addStopsAtTheLimit() {
        var list = BeatList(beats: Array(repeating: AnimationBeat(duration: 0.1), count: MadeAnimation.maxBeats), selected: 0)
        list.add(); list.duplicate(); list.split()
        #expect(list.beats.count == MadeAnimation.maxBeats)
    }

    @Test func duplicateSelectsTheCopy() {
        var list = BeatList(beats: beats(0.5, 1), selected: 1)
        list.duplicate()
        #expect(list.beats.map(\.duration) == [0.5, 1, 1])
        #expect(list.selected == 2)
    }

    @Test func splitHalvesTheBeatAndTheHopStaysWithTheFirst() {
        var list = BeatList(beats: [AnimationBeat(duration: 0.8, hop: true), AnimationBeat(duration: 1)], selected: 0)
        list.split()
        #expect(list.beats.map(\.duration) == [0.4, 0.4, 1])
        #expect(list.beats[0].hop && !list.beats[1].hop)
        #expect(list.selected == 0)
    }

    @Test func aBeatUnderATenthIsNotSplit() {
        var list = BeatList(beats: beats(0.09), selected: 0)
        list.split()
        #expect(list.beats.count == 1)
    }

    @Test func removeKeepsOneBeatAndAValidSelection() {
        var list = BeatList(beats: beats(1, 2, 3), selected: 2)
        list.remove()
        #expect(list.beats.map(\.duration) == [1, 2])
        #expect(list.selected == 1)
        list.remove(); list.remove()
        #expect(list.beats.count == 1)
        #expect(list.selected == 0)
    }

    @Test func pasteKeepsTheBeatsOwnLength() {
        var list = BeatList(beats: beats(1, 2), selected: 1)
        let pasted = list.paste(AnimationBeat(duration: 0.3, mood: "angry", tilt: 5))
        #expect(pasted)
        #expect(list.beats[1].duration == 2 && list.beats[1].mood == "angry" && list.beats[1].tilt == 5)
        var empty = BeatList(beats: [], selected: 0)
        let pastedIntoEmpty = empty.paste(AnimationBeat(duration: 1))
        #expect(!pastedIntoEmpty)
    }

    @Test func quickEditsInARowAreOneUndoStep() {
        var history = BeatHistory()
        let t = Date(timeIntervalSince1970: 1000)
        history.remember(beats(1), at: t)
        history.remember(beats(1.1), at: t.addingTimeInterval(0.2))
        history.remember(beats(1.2), at: t.addingTimeInterval(0.4))
        #expect(history.canUndo)
        let back = history.undo(current: beats(1.3))
        #expect(back?.map(\.duration) == [1])
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test func aPauseStartsANewStepAndAnEditClearsRedo() {
        var history = BeatHistory()
        let t = Date(timeIntervalSince1970: 1000)
        history.remember(beats(1), at: t)
        history.remember(beats(2), at: t.addingTimeInterval(2))
        #expect(history.undo(current: beats(3))?.map(\.duration) == [2])
        #expect(history.undo(current: beats(2))?.map(\.duration) == [1])
        #expect(history.redo(current: beats(1))?.map(\.duration) == [2])
        history.remember(beats(2), at: t.addingTimeInterval(5))
        history.remember(beats(2), at: t.addingTimeInterval(10))
        #expect(!history.canRedo)
    }

    @Test func theChangeFromUndoItselfIsNotRemembered() {
        var history = BeatHistory()
        let t = Date(timeIntervalSince1970: 1000)
        history.remember(beats(1), at: t)
        _ = history.undo(current: beats(2))
        history.remember(beats(2), at: t.addingTimeInterval(5))
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test func historyKeepsAHundredSteps() {
        var history = BeatHistory()
        var t = Date(timeIntervalSince1970: 1000)
        for i in 0..<150 { history.remember(beats(Double(i) + 1), at: t); t.addTimeInterval(1) }
        var steps = 0
        while history.undo(current: beats(1)) != nil { steps += 1 }
        #expect(steps == 100)
    }

    @Test func trackMapsTimeToPositionAndBack() {
        let layout = TrackLayout(durations: [1, 2], widths: [100, 200])
        #expect(layout.starts == [0, 103])
        #expect(layout.x(at: 0) == 0)
        #expect(layout.x(at: 0.5) == 50)
        #expect(layout.x(at: 2) == CGFloat(203))
        #expect(layout.x(at: 9) == 303)
        #expect(layout.time(at: 50) == 0.5)
        #expect(layout.time(at: 203) == 2)
        #expect(layout.time(at: 5000) == 3)
        #expect(layout.time(at: -10) == 0)
    }
}
