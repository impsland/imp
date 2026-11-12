import Foundation

/// Weights for cross-fading between states (moods) that can change again before the last fade has
/// finished. The current state's weight rises linearly to 1 over `duration` (the others give up
/// theirs in proportion), so any sequence of changes is continuous: nothing ever jumps, and a
/// half-faded state simply keeps fading out while the next one fades in.
public struct BlendWeights<Key: Hashable> {
    public let duration: Double
    private var weights: [Key: Double] = [:]
    private var last: Double?

    /// Frames further apart than this (seconds) are a pause, not time passing.
    public static var resumeAfter: Double { 0.1 }

    public init(duration: Double) {
        self.duration = max(duration, 0.001)
    }

    /// Moves the weights toward `current` as of time `t`. The first call (or time running backwards)
    /// starts with `current` alone.
    public mutating func advance(to current: Key, at t: Double) {
        guard let previous = last, t >= previous, !weights.isEmpty else {
            weights = [current: 1]
            last = t
            return
        }
        // A long gap means drawing paused (resting pace) and this is the first frame back: fade
        // from here rather than finishing the fade in one go.
        let gap = t - previous
        let step = (gap > Self.resumeAfter ? 1.0 / 60 : gap) / duration
        last = t
        // The current state takes `step` of the weight from the others, in proportion to what each
        // has, so the weights always sum to 1 and none ever jumps.
        let others = weights.filter { $0.key != current }
        let total = others.values.reduce(0, +)
        let moved = min(step, total)
        guard total > 1e-9, moved < total else {
            weights = [current: 1]
            return
        }
        for (key, w) in others { weights[key] = w * (total - moved) / total }
        weights[current] = 1 - (total - moved)
    }

    /// Only the current state is left: nothing is fading.
    public var isSettled: Bool { weights.count <= 1 && (weights.values.first ?? 1) >= 1 }

    /// The states to mix and how much of each, eased (smoothstep) and normalised to sum to 1.
    /// With two states this is the familiar smooth cross-fade.
    public var mix: [(key: Key, weight: Double)] {
        let eased = weights.map { (key: $0.key, weight: Self.smooth($0.value)) }.filter { $0.weight > 0 }
        let total = eased.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        return eased.map { (key: $0.key, weight: $0.weight / total) }
    }

    private static func smooth(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k * k * (3 - 2 * k)
    }
}
