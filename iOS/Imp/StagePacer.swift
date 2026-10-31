import ImpKit
import SwiftUI

/// How fast the stage needs to be drawn.
enum StagePace: Equatable {
    /// Something moves: the display's own rate.
    case lively
    /// The Imps only breathe, blink and float: a calm rate.
    case calm
    /// Nobody is on the stage: no frames at all.
    case idle
}

/// Decides the stage's pace from what the engine finds each frame, and tells the view when it
/// changes (once, not every frame). Like the engine it is not observable: the timeline reads and
/// feeds it while the view body runs.
@MainActor
final class StagePacer {
    private(set) var pace = StagePace.lively
    /// Called (after the current frame) when the pace changes.
    var onChange: (StagePace) -> Void = { _ in }
    /// Two Imps are still drifting apart.
    var separating = false

    private var hold = LivelyHold()
    private var moods: [UUID: Mood] = [:]

    /// Something is about to move (a finger, an arrival, a round): the next frames are lively.
    func wake(at date: Date = Date()) {
        hold.extend(to: date.addingTimeInterval(FramePolicy.settle))
        publish(.lively)
    }

    /// An Imp's mood as drawn this frame. A change fades over a moment, which wants smooth frames.
    func note(mood: Mood, of id: UUID, at date: Date) {
        if let before = moods.updateValue(mood, forKey: id), before != mood {
            hold.extend(to: date.addingTimeInterval(FramePolicy.settle))
        }
    }

    /// Ends a frame: `moving` is whether anything on the stage is, `empty` whether there is nobody.
    func settle(moving: Bool, empty: Bool, at date: Date) {
        publish(empty ? .idle : hold.lively(moving: moving || separating, at: date) ? .lively : .calm)
        separating = false
    }

    private func publish(_ next: StagePace) {
        guard next != pace else { return }
        pace = next
        // Not while a view body runs: the view's state changes after the frame.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onChange(self.pace)
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
