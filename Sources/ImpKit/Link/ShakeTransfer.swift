import Foundation

/// The settings of "shake to send" on the iPhone. Kept in `UserDefaults` so the app and the tests read them the same way.
public struct ShakeSettings: Sendable, Equatable {
    /// How hard a shake has to be.
    public enum Sensitivity: String, CaseIterable, Sendable, Identifiable {
        case gentle, normal, firm
        public var id: String { rawValue }
        /// Acceleration (g) each push of the shake needs (see `JoltDetector`).
        public var threshold: Double {
            switch self {
            case .gentle: 1.5
            case .normal: 2.0
            case .firm: 2.8
            }
        }
        /// Pushes back and forth that make a shake.
        public var pushes: Int { self == .firm ? 5 : 4 }
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
    public var nearbyWindow: TimeInterval = 10 * 60

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

/// Which Imp a shake sends and where, decided from what the phone knows. Pure: no clock, no network,
/// everything is passed in. The reasons are in `docs/TRANSFER.md`.
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
        if peer.connected && !peer.viaHop { return .near }
        if let seen = peer.lastNearby, now.timeIntervalSince(seen) <= window { return .recent }
        return .far
    }

    /// The Imp a shake moves: the one carried or thrown last, then the one touched last, then by name
    /// so the same Imp is picked every time.
    public static func pick(_ imps: [Imp]) -> Imp? {
        imps.min { a, b in
            let (am, bm) = (a.lastMoved ?? .distantPast, b.lastMoved ?? .distantPast)
            if am != bm { return am > bm }
            let (at, bt) = (a.lastTouched ?? .distantPast, b.lastTouched ?? .distantPast)
            if at != bt { return at > bt }
            return (a.name, a.id.uuidString) < (b.name, b.id.uuidString)
        }
    }

    /// `side`: the way the shake started, if it can tell.
    public static func decide(imps: [Imp], peers: [Peer], side: LinkSide?, settings: ShakeSettings, now: Date) -> Decision {
        guard settings.enabled else { return .nothing(.off) }
        guard let imp = pick(imps) else { return .nothing(.noImps) }
        // Only a linked device that is connected is ever a target.
        let eligible = peers.filter { $0.linked && $0.connected }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        guard !eligible.isEmpty else { return .nothing(.nobodyAround) }

        let tiers = eligible.map { (peer: $0, closeness: closeness(of: $0, now: now, window: settings.nearbyWindow)) }
        let near = tiers.filter { $0.closeness == .near }.map(\.peer)
        let recent = tiers.filter { $0.closeness == .recent }.map(\.peer)
        let pool = near.isEmpty ? recent : near
        guard !pool.isEmpty else { return .ask(imp: imp.id, choices: eligible.map(\.id), why: .farAway) }

        var target: Peer?
        if pool.count == 1 {
            target = pool[0]
        } else if settings.direction == .leftRight, pool.count == 2, let side {
            target = side == .right ? pool[0] : pool[1]
        }
        guard let target else { return .ask(imp: imp.id, choices: pool.map(\.id), why: .severalNearby) }
        if !target.mine && settings.asksForFriends { return .ask(imp: imp.id, choices: [target.id], why: .friend) }
        return .send(imp: imp.id, to: target.id)
    }
}
