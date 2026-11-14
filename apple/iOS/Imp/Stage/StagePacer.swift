import ImpKit
import SwiftUI

/// Decides how often a picture needs drawing from what each frame finds, and tells the view when it
/// changes (once, not every frame). It does not decide the rate: it names the `Activity`, and
/// `FramePolicy` turns that into frames. Like the engine it is not observable: the timeline reads
/// and feeds it while the view body runs.
///
/// The stage, the Imp on the first screen and the Imps in the chat each own one.
@MainActor
final class StagePacer {
    private(set) var activity = FramePolicy.Activity.lively
    /// Called (after the current frame) when the activity changes.
    var onChange: (FramePolicy.Activity) -> Void = { _ in }
    /// Two Imps are still drifting apart.
    var separating = false

    private var hold = LivelyHold()
    private var moods: [UUID: Mood] = [:]
    /// Whether the last frame drew an Imp that is awake (true until a frame says otherwise).
    private var awakeSeen = true
    /// Whether the last frame drew something with a slow motion of its own (a mood, dots).
    private var busySeen = false

    /// Something is about to move (a finger, an arrival, a round): the next frames are lively.
    func wake(at date: Date = Date()) {
        hold.extend(to: date.addingTimeInterval(FramePolicy.settle))
        publish(.lively)
    }

    /// An Imp as drawn this frame: its mood, whether it is `awake`, and whether something about it is
    /// `animated` beyond its mood (dots bouncing over its head). A change of mood fades over a moment,
    /// which wants smooth frames, so it wakes the pace even if the stage had gone still.
    func note(mood: Mood, of id: UUID, awake: Bool, animated: Bool = false, at date: Date) {
        // Woken at the real time: a picture at rest is drawn again with the time of its last frame.
        if let before = moods.updateValue(mood, forKey: id), before != mood { wake(at: max(date, Date())) }
        awakeSeen = awakeSeen || awake
        // An idle Imp only breathes, floats and blinks. A sleeping one does nothing at all.
        busySeen = busySeen || animated || (awake && mood != .idle)
    }

    /// Ends a frame: `moving` is whether anything on the stage is (a finger on it counts), `empty`
    /// whether there is nobody, `animated` whether something besides the Imps needs drawing (a game's
    /// card). A stage where every Imp sleeps and nothing moves is still, and one where the Imps that
    /// are awake are idle is at rest.
    func settle(moving: Bool, empty: Bool, animated: Bool = false, at date: Date) {
        let sleeping = !awakeSeen, busy = busySeen || animated
        awakeSeen = false
        busySeen = false
        let lively = hold.lively(moving: moving || separating, at: date)
        publish(empty || (sleeping && !busy && !lively) ? .still : lively ? .lively : busy ? .calm : .resting)
        separating = false
    }

    private func publish(_ next: FramePolicy.Activity) {
        guard next != activity else { return }
        activity = next
        // Not while a view body runs: the view's state changes after the frame.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onChange(self.activity)
        }
    }
}

extension StageEngine {
    /// Whether anything on the stage moves right now, or is about to.
    func isMoving(at date: Date) -> Bool {
        // A finished game's card alone is drawn at the calm pace.
        if touch != nil || round.map({ !$0.isSettled }) == true || echo.map({ !$0.round.isOver || !$0.sparks.isEmpty || !$0.popups.isEmpty }) == true { return true }
        return bodies.values.contains { b in
            b.phase != .free || b.enteringFrom != nil || b.vel != .zero || b.dizzyUntil > date
                || b.performance.map { date.timeIntervalSince($0.started) < $0.duration } ?? false
        }
    }
}
