import CoreGraphics
import Foundation
import ImpKit

/// The beats of an animation being edited and the one picked, with the edits the timeline offers.
struct BeatList {
    var beats: [AnimationBeat]
    var selected: Int

    private var picked: AnimationBeat? { beats.indices.contains(selected) ? beats[selected] : nil }

    /// A copy of the picked beat's pose after it, without its hop, glyph or move.
    mutating func add() {
        guard beats.count < MadeAnimation.maxBeats else { return }
        var b = picked ?? AnimationBeat(duration: 0.5)
        b.hop = false
        b.glyph = nil
        b.move = nil; b.times = nil; b.reverse = nil
        let at = min(selected + 1, beats.count)
        beats.insert(b, at: at)
        selected = at
    }

    mutating func duplicate() {
        guard let b = picked, beats.count < MadeAnimation.maxBeats else { return }
        beats.insert(b, at: selected + 1)
        selected += 1
    }

    /// Two halves of the picked beat. A hop stays with the first, a move is split between them.
    mutating func split() {
        guard var a = picked, beats.count < MadeAnimation.maxBeats, a.duration >= 0.1 else { return }
        let half = AnimationBeat.round(a.duration / 2)
        var b = a
        a.duration = half
        b.duration = AnimationBeat.round(max(0.05, b.duration - half))
        b.hop = false
        beats[selected] = a
        beats.insert(b, at: selected + 1)
    }

    mutating func remove() {
        guard beats.count > 1, beats.indices.contains(selected) else { return }
        beats.remove(at: selected)
        selected = min(selected, beats.count - 1)
    }

    /// The copied pose on the picked beat (it keeps its own length). False when there is no beat to take it.
    mutating func paste(_ pose: AnimationBeat) -> Bool {
        guard beats.indices.contains(selected) else { return false }
        var b = pose
        b.duration = beats[selected].duration
        beats[selected] = b
        return true
    }
}

/// Earlier versions of the beats, for undo and redo. Quick edits in a row (a slider dragged, an
/// edge pulled) are one step.
struct BeatHistory {
    private var steps: [[AnimationBeat]] = []
    private var undone: [[AnimationBeat]] = []
    private var lastEdit = Date.distantPast
    private var restoring = false

    var canUndo: Bool { !steps.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    /// Notes that the beats changed from `old`.
    mutating func remember(_ old: [AnimationBeat], at now: Date = Date()) {
        if restoring { restoring = false; return }
        if now.timeIntervalSince(lastEdit) > 0.6 {
            steps.append(old)
            if steps.count > 100 { steps.removeFirst() }
            undone = []
        }
        lastEdit = now
    }

    /// The beats to go back to, if any.
    mutating func undo(current: [AnimationBeat]) -> [AnimationBeat]? {
        guard let last = steps.popLast() else { return nil }
        undone.append(current)
        return restore(last, current: current)
    }

    mutating func redo(current: [AnimationBeat]) -> [AnimationBeat]? {
        guard let next = undone.popLast() else { return nil }
        steps.append(current)
        return restore(next, current: current)
    }

    private mutating func restore(_ list: [AnimationBeat], current: [AnimationBeat]) -> [AnimationBeat] {
        restoring = list != current
        lastEdit = .distantPast
        return list
    }
}

/// Where each beat sits on the timeline track, and the time at a point on it.
struct TrackLayout {
    static let gap: CGFloat = 3

    let durations: [Double]
    let widths: [CGFloat]
    let starts: [CGFloat]

    init(durations: [Double], widths: [CGFloat]) {
        self.durations = durations
        self.widths = widths
        var x: CGFloat = 0
        starts = widths.map { w in defer { x += w + Self.gap }; return x }
    }

    var end: CGFloat { (starts.last ?? 0) + (widths.last ?? 0) }

    /// The track's x for a time in the animation (beats shorter than a tile still get a whole tile).
    func x(at t: Double) -> CGFloat {
        var left = t
        for (i, d) in durations.enumerated() {
            if left <= d { return starts[i] + widths[i] * CGFloat(left / max(d, 0.001)) }
            left -= d
        }
        return end
    }

    /// The time at a point on the track.
    func time(at x: CGFloat) -> Double {
        var t = 0.0
        for (i, d) in durations.enumerated() {
            if x < starts[i] + widths[i] + Self.gap { return t + d * Double(max(0, min(1, (x - starts[i]) / widths[i]))) }
            t += d
        }
        return t
    }
}
