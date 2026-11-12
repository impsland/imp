import Foundation
import ImpCore

/// The settings of "shake to send" on the iPhone. Kept in `UserDefaults` so the app and the tests read them the same way.
public struct ShakeSettings: Sendable, Equatable {
    /// How hard a shake has to be.
    public enum Sensitivity: String, CaseIterable, Sendable, Identifiable {
        case gentle, normal, firm
        public var id: String { rawValue }
        /// Acceleration (g) each push of the shake needs (see `JoltDetector`).
        public var threshold: Double { linkShakeStrength(sensitivityName: rawValue).threshold }
        /// Pushes back and forth that make a shake.
        public var pushes: Int { Int(linkShakeStrength(sensitivityName: rawValue).pushes) }
    }

    /// What the side the shake starts toward means.
    public enum Direction: String, CaseIterable, Sendable, Identifiable {
        /// It doesn't. The device that is nearby goes.
        case either
        /// With two devices nearby, a shake to the right sends to the first and to the left to the second.
        case leftRight
        public var id: String { rawValue }
    }

    public var enabled = true
    public var sensitivity = Sensitivity.normal
    public var direction = Direction.either
    /// A device that is linked but not marked as one of yours is asked about first (it is somebody else's screen).
    public var asksForFriends = true
    /// How long a device counts as "nearby" after it was last seen on the same network.
    public var nearbyWindow: TimeInterval = linkShakeNearbyWindow()

    public init() {}

    public static let enabledKey = "shakeToSend"
    public static let sensitivityKey = "shakeSensitivity"
    public static let directionKey = "shakeDirection"
    public static let friendsKey = "shakeAsksForFriends"

    public init(defaults: UserDefaults) {
        if defaults.object(forKey: Self.enabledKey) != nil { enabled = defaults.bool(forKey: Self.enabledKey) }
        sensitivity = defaults.string(forKey: Self.sensitivityKey).flatMap(Sensitivity.init) ?? .normal
        direction = defaults.string(forKey: Self.directionKey).flatMap(Direction.init) ?? .either
        if defaults.object(forKey: Self.friendsKey) != nil { asksForFriends = defaults.bool(forKey: Self.friendsKey) }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(sensitivity.rawValue, forKey: Self.sensitivityKey)
        defaults.set(direction.rawValue, forKey: Self.directionKey)
        defaults.set(asksForFriends, forKey: Self.friendsKey)
    }
}

/// Which Imp a shake sends and where, decided by the core from what the phone knows. The reasons are in `docs/concepts/transfer.md`.
public enum ShakeTransfer {
    /// An Imp that is on the phone's screen and free to go.
    public struct Imp: Sendable, Equatable {
        public var id: UUID
        public var name: String
        /// When it was last carried, thrown or flew in.
        public var lastMoved: Date?
        /// When a finger last touched it.
        public var lastTouched: Date?

        public init(id: UUID, name: String, lastMoved: Date? = nil, lastTouched: Date? = nil) {
            self.id = id; self.name = name; self.lastMoved = lastMoved; self.lastTouched = lastTouched
        }
    }

    /// A device the phone knows.
    public struct Peer: Sendable, Equatable {
        public var id: UUID
        public var name: String
        /// Linked: it is in the phone's book of devices. Nothing else is ever a target.
        public var linked: Bool
        /// Connected right now (an Imp can only be thrown to a connected device).
        public var connected: Bool
        /// Connected through the Hop server (the internet) and not the local network.
        public var viaHop: Bool
        /// The last time it was connected over the local network.
        public var lastNearby: Date?
        /// Marked as one of the owner's own devices.
        public var mine: Bool

        public init(id: UUID, name: String, linked: Bool = true, connected: Bool = true, viaHop: Bool = false,
                    lastNearby: Date? = nil, mine: Bool = true) {
            self.id = id; self.name = name; self.linked = linked; self.connected = connected
            self.viaHop = viaHop; self.lastNearby = lastNearby; self.mine = mine
        }
    }

    public enum Closeness: Sendable, Equatable { case near, recent, far }

    public enum Why: Sendable, Equatable {
        /// Several devices are nearby and the shake doesn't say which.
        case severalNearby
        /// Linked, but not one of the owner's own devices.
        case friend
        /// No device was seen nearby lately: it may be far away.
        case farAway
    }

    public enum Nothing: Sendable, Equatable {
        case off, noImps, nobodyAround
    }

    public enum Decision: Sendable, Equatable {
        /// Send it now. The person sees where it went and can undo it for a few seconds.
        case send(imp: UUID, to: UUID)
        /// Ask first: `choices` are the devices to pick from, in the order to show them.
        case ask(imp: UUID, choices: [UUID], why: Why)
        case nothing(Nothing)
    }

    /// How close a device is: on the local network now, seen there lately, or neither.
    public static func closeness(of peer: Peer, now: Date, window: TimeInterval) -> Closeness {
        switch (try? linkShakeCloseness(peer: core(peer), now: now.timeIntervalSince1970, window: window)) ?? "far" {
        case "near": .near
        case "recent": .recent
        default: .far
        }
    }

    /// What a shake does, decided by the core. `side`: the way the shake started, if it can tell.
    public static func decide(imps: [Imp], peers: [Peer], side: LinkSide?, settings: ShakeSettings, now: Date) -> Decision {
        let imps = imps.map {
            LinkShakeImp(id: $0.id.uuidString, name: $0.name, lastMoved: $0.lastMoved?.timeIntervalSince1970,
                         lastTouched: $0.lastTouched?.timeIntervalSince1970)
        }
        let settings = LinkShakeSettings(enabled: settings.enabled, sensitivity: settings.sensitivity.rawValue,
                                         direction: settings.direction.rawValue, asksForFriends: settings.asksForFriends,
                                         nearbyWindow: settings.nearbyWindow)
        guard let decision = try? linkShakeDecide(imps: imps, peers: peers.map(core), side: side?.rawValue,
                                                  settings: settings, now: now.timeIntervalSince1970) else {
            return .nothing(.nobodyAround)
        }
        switch decision {
        case .send(let imp, let to):
            guard let imp = UUID(uuidString: imp), let to = UUID(uuidString: to) else { return .nothing(.nobodyAround) }
            return .send(imp: imp, to: to)
        case .ask(let imp, let choices, let why):
            guard let imp = UUID(uuidString: imp) else { return .nothing(.nobodyAround) }
            let why: Why = switch why { case "friend": .friend; case "farAway": .farAway; default: .severalNearby }
            return .ask(imp: imp, choices: choices.compactMap(UUID.init(uuidString:)), why: why)
        case .nothing(let why):
            let reason: Nothing = switch why { case "off": .off; case "noImps": .noImps; default: .nobodyAround }
            return .nothing(reason)
        }
    }

    private static func core(_ peer: Peer) -> LinkShakePeer {
        LinkShakePeer(id: peer.id.uuidString, name: peer.name, linked: peer.linked, connected: peer.connected,
                      viaHop: peer.viaHop, lastNearby: peer.lastNearby?.timeIntervalSince1970, mine: peer.mine)
    }
}
