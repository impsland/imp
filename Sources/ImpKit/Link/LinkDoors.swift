import Foundation

/// How an Imp's body got to the screen it is on.
public enum LinkTravel: Codable, Sendable, Equatable {
    /// It is at home.
    case home
    /// It came in through `side` of this screen, from the device `from`.
    case visit(side: LinkSide, from: UUID)
}

/// Where a thrown Imp goes (see "Doors" in `docs/LINK.md`). Pure: the screen asks with what is
/// connected right now and gets a device, or the reason it bounces.
public enum LinkDoors {
    /// Why an Imp bounces back instead of leaving.
    public enum Bounce: Sendable, Equatable {
        /// No device is connected.
        case nobodyConnected
        /// It came in by this side from a device that isn't connected any more.
        case wayBackIsClosed
        /// Nothing but the device it came from is connected, and that's not the way on.
        case nowhereElse
    }

    public enum Outcome: Sendable, Equatable {
        case to(UUID)
        case bounce(Bounce)
    }

    /// One device's share of a side: the heights from `top` to `bottom` (0 is the top).
    public struct Band: Sendable, Equatable {
        public var device: UUID
        public var top: Double
        public var bottom: Double
    }

    /// The devices a side of this screen leads to, in a stable order.
    public static func reach(side: LinkSide, travel: LinkTravel, connected: [UUID]) -> [UUID] {
        let all = Array(Set(connected)).sorted { $0.uuidString < $1.uuidString }
        switch travel {
        case .home:
            return all
        case .visit(let entry, let from):
            // The side it came in by leads back to where it came from; the other side leads on.
            return side == entry ? all.filter { $0 == from } : all.filter { $0 != from }
        }
    }

    /// The side split into equal bands from top to bottom, one per device (for labelling).
    public static func bands(side: LinkSide, travel: LinkTravel, connected: [UUID]) -> [Band] {
        let devices = reach(side: side, travel: travel, connected: connected)
        let n = Double(devices.count)
        return devices.enumerated().map { Band(device: $1, top: Double($0) / n, bottom: Double($0 + 1) / n) }
    }

    /// Where an Imp thrown off `side` at `height` (0 the top, 1 the bottom) goes.
    public static func door(side: LinkSide, height: Double, travel: LinkTravel, connected: [UUID]) -> Outcome {
        let devices = reach(side: side, travel: travel, connected: connected)
        guard !devices.isEmpty else {
            guard !connected.isEmpty else { return .bounce(.nobodyConnected) }
            if case .visit(let entry, _) = travel, side == entry { return .bounce(.wayBackIsClosed) }
            return .bounce(.nowhereElse)
        }
        let h = height.isFinite ? min(max(height, 0), 1) : 0.5
        return .to(devices[min(Int(h * Double(devices.count)), devices.count - 1)])
    }
}
