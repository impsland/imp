import Foundation
import ImpKit

/// An animation acted out by a figure that isn't a live desktop Imp (the Imp in the doorway, the
/// settings preview): the same beats `ImpLife` plays, driven by the clock instead of a timer.
struct Performance: Equatable {
    let reaction: Reaction
    let started: Date
    let steps: [AnticStep]

    init(_ reaction: Reaction, at date: Date = Date()) {
        self.reaction = reaction
        started = date
        steps = Antics.steps(for: reaction, work: .zero)
    }

    var duration: Double { steps.reduce(0) { $0 + $1.duration } }

    struct Beat {
        var step: AnticStep
        /// Seconds since this beat began.
        var elapsed: Double
        /// The glyph showing (see `[AnticStep].glyph(at:elapsed:)`).
        var glyph: (glyph: Glyph, age: Double, remaining: Double)?
        /// Seconds since the last hop began (nil: none under way).
        var hopSince: Double?
    }

    /// The beat playing at `date` (nil before the start or after the end).
    func beat(at date: Date) -> Beat? {
        var t = date.timeIntervalSince(started)
        guard t >= 0 else { return nil }
        var hopSince: Double?
        for (i, step) in steps.enumerated() {
            if step.hop { hopSince = 0 }
            if t < step.duration {
                return Beat(step: step, elapsed: t, glyph: steps.glyph(at: i, elapsed: t), hopSince: hopSince.map { $0 + t })
            }
            t -= step.duration
            hopSince = hopSince.map { $0 + step.duration }
        }
        return nil
    }
}
