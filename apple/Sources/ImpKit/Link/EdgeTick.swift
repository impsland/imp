import Foundation
import ImpCore

/// When a carried Imp earns the tick that says a door is at the side it heads for: once, as it crosses a line
/// near the side while moving towards it. Staying on the line, leaving it, or moving back from the side is silent.
public struct EdgeTick: Equatable {
    /// How close to a side (points from it) the line is.
    public let distance: Double
    /// The side the Imp was last on the near end of the line of, if it is.
    private var inside: LinkSide?
    private var started = false

    public init(distance: Double) {
        self.distance = distance
    }

    /// One look at the carried Imp: the side it is nearer to, how far it is from it, and how fast it moves towards
    /// it (points a second, negative when it moves back). True when it just crossed the line towards the side.
    /// The first look after `release` only learns where the Imp is, so one picked up near a side is silent.
    public mutating func carry(near side: LinkSide, distance from: Double, speed: Double) -> Bool {
        let isInside = from <= distance
        defer {
            inside = isInside ? side : nil
            started = true
        }
        return started && isInside && inside != side && speed > 0
    }

    /// The Imp was let go or thrown.
    public mutating func release() {
        inside = nil
        started = false
    }
}
