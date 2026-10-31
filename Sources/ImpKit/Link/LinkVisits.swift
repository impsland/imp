import Foundation

/// The Imps visiting this device (see "Visit" in `docs/LINK.md`): for each one, how it came in, its
/// home's card and the ticket that lets this device act for it at its home. Plus the releases that
/// couldn't be delivered yet. Pure, so it can be tested without a network; the book keeps it.
public struct Visits: Codable, Sendable, Equatable {
    public struct Visit: Codable, Sendable, Equatable, Identifiable {
        public var imp: LinkImp
        public var home: LinkCard
        public var ticket: Data
        /// The side of this screen it came in by, and the device that threw it.
        public var side: LinkSide
        public var from: UUID

        public var id: UUID { imp.id }
        public var travel: LinkTravel { .visit(side: side, from: from) }
    }

    /// A visiting Imp that was sent home, whose home hasn't heard yet.
    public struct Release: Codable, Sendable, Equatable {
        public var imp: UUID
        public var home: LinkCard
        public var ticket: Data
        public var date: Date
    }

    public private(set) var visits: [Visit] = []
    public private(set) var releases: [Release] = []

    /// A release not delivered in this long is dropped (its home is gone for good).
    public static let releaseLife: TimeInterval = 14 * 24 * 3600

    public init() {}

    public func visit(of imp: UUID) -> Visit? { visits.first { $0.imp.id == imp } }
    public var isFull: Bool { visits.count >= LinkProtocol.maxVisits }

    /// How the Imp got to this screen: a visitor's way in, or nothing special at home.
    public func travel(of imp: UUID) -> LinkTravel { visit(of: imp)?.travel ?? .home }

    /// An Imp arrives. False if there is no room (a returning visitor always has).
    @discardableResult
    public mutating func arrive(_ imp: LinkImp, entry: LinkEntry, from: UUID, home: LinkCard, ticket: Data) -> Bool {
        guard visit(of: imp.id) != nil || !isFull else { return false }
        visits.removeAll { $0.imp.id == imp.id }
        releases.removeAll { $0.imp == imp.id }
        visits.append(Visit(imp: imp, home: home, ticket: ticket, side: entry.side, from: from))
        return true
    }

    /// The home rotated the ticket after a claim.
    public mutating func rotate(_ imp: UUID, ticket: Data) {
        guard let i = visits.firstIndex(where: { $0.imp.id == imp }) else { return }
        visits[i].ticket = ticket
    }

    /// The home rotated the ticket of an Imp already sent home, so its release can go on. False
    /// unless a release for it is waiting at that home.
    public mutating func rotateRelease(_ imp: UUID, ticket: Data, at home: UUID) -> Bool {
        guard let i = releases.firstIndex(where: { $0.imp == imp && $0.home.id == home }) else { return false }
        releases[i].ticket = ticket
        return true
    }

    /// Looks changed at the home.
    public mutating func update(_ imp: LinkImp) {
        guard let i = visits.firstIndex(where: { $0.imp.id == imp.id }) else { return }
        visits[i].imp = imp
    }

    /// The Imp leaves this device (passed on, or the home said `gone`). Returns the visit.
    @discardableResult
    public mutating func leave(_ imp: UUID) -> Visit? {
        guard let i = visits.firstIndex(where: { $0.imp.id == imp }) else { return nil }
        return visits.remove(at: i)
    }

    /// Sends a visiting Imp home from here (deleted, or its home forgotten): it leaves now and the
    /// release waits until the home has heard.
    @discardableResult
    public mutating func sendHome(_ imp: UUID, now: Date = Date()) -> Visit? {
        guard let visit = leave(imp) else { return nil }
        releases.removeAll { $0.imp == imp }
        releases.append(Release(imp: imp, home: visit.home, ticket: visit.ticket, date: now))
        return visit
    }

    /// Sends every Imp whose home is `home` back to it. Returns them.
    @discardableResult
    public mutating func sendHome(of home: UUID, now: Date = Date()) -> [Visit] {
        visits.filter { $0.home.id == home }.compactMap { sendHome($0.imp.id, now: now) }
    }

    /// The home heard the release (or no longer knows the Imp).
    public mutating func delivered(_ imp: UUID, at home: UUID) {
        releases.removeAll { $0.imp == imp && $0.home.id == home }
    }

    /// Drops releases that waited too long.
    public mutating func expire(now: Date = Date()) {
        releases.removeAll { now.timeIntervalSince($0.date) > Self.releaseLife }
    }

    /// What to claim when connected to `home`: every Imp held from it, with the ticket held. Only a
    /// device with the key the Imp's card has is the home: tickets go to nobody else.
    public func claims(at home: LinkDevice) -> [(imp: UUID, ticket: Data)] {
        visits.filter { isHome(home, $0.home) }.map { ($0.imp.id, $0.ticket) }
    }

    public func pendingReleases(at home: LinkDevice) -> [Release] { releases.filter { isHome(home, $0.home) } }

    /// The key of a home this device has business with, by its id.
    public func homeKey(of id: UUID) -> Data? { homes.first { $0.id == id }?.device.key }

    private func isHome(_ device: LinkDevice, _ card: LinkCard) -> Bool {
        card.id == device.id && LinkCrypto.equal(card.device.key, device.key)
    }

    /// The homes this device has business with: where visiting Imps think, and where releases wait.
    public var homes: [LinkCard] {
        var seen = Set<UUID>()
        return (visits.map(\.home) + releases.map(\.home)).filter { seen.insert($0.id).inserted }
    }
}
