import Foundation
import ImpCore

/// When the device-name hint at a screen edge may show. A carried Imp near a side is probably being
/// considered for a hand-over, so the hint helps. One that is flicked to the side at throw speed is being
/// thrown on purpose and must not be covered by it: the speed limit is the core's throw speed.
public struct EdgeDwell: Equatable {
    /// How long the Imp must stay near a side before the hint shows.
    public let delay: TimeInterval
    /// The speed towards the side (points a second) above which the Imp is on its way somewhere, not waiting.
    public let maxSpeed: Double
    private var side: LinkSide?
    private var since: Date?

    public init(delay: TimeInterval, maxSpeed: Double) {
        self.delay = delay
        self.maxSpeed = maxSpeed
    }

    /// One look at the carried Imp: the side it is near (nil when away from every side) and how fast it is
    /// moving towards it. Moving quickly, or changing sides, starts the wait over. So does leaving the side.
    public mutating func carry(near side: LinkSide?, speed: Double, at now: Date) {
        guard let side, speed <= maxSpeed else {
            self.side = nil
            since = nil
            return
        }
        if side != self.side || since == nil {
            self.side = side
            since = now
        }
    }

    /// The Imp was let go or thrown.
    public mutating func release() {
        side = nil
        since = nil
    }

    /// The side the hint is for, once the Imp has waited near it long enough.
    public func shown(at now: Date) -> LinkSide? {
        guard let side, let since, now.timeIntervalSince(since) >= delay else { return nil }
        return side
    }
}
