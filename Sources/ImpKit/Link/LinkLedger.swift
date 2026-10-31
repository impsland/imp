import Foundation

/// The home's record of its Imps that are away (see "Tickets" in `docs/LINK.md`): who holds each
/// one and a hash of its current ticket. The home is the source of truth: a holder is only a holder
/// while this says so. Pure, so the races can be tested without a network.
public struct AwayLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var imp: UUID
        public var holder: UUID
        /// `LinkCrypto.hash(ticket:)` of the current ticket.
        public var ticket: Data
        /// Counts every new holder or ticket, so a stale answer can be told from a fresh one.
        public var generation: Int
    }

    /// A holder to be told `gone` when it next connects.
    public struct Notice: Codable, Sendable, Equatable {
        public var device: UUID
        public var imp: UUID
    }

    public enum Claim: Sendable, Equatable {
        /// The claimant is the holder now, with this new ticket; `previous` (if any) is to be told `gone`.
        case granted(ticket: Data, previous: UUID?)
        /// Not the current ticket (stale, wrong, or the Imp isn't away): the claimant's body must go.
        case refused
    }

    public private(set) var entries: [Entry] = []
    public private(set) var notices: [Notice] = []

    public init() {}

    public func entry(of imp: UUID) -> Entry? { entries.first { $0.imp == imp } }
    public func holder(of imp: UUID) -> UUID? { entry(of: imp)?.holder }
    public func isAway(_ imp: UUID) -> Bool { entry(of: imp) != nil }

    /// The Imps `device` holds.
    public func held(by device: UUID) -> [UUID] { entries.filter { $0.holder == device }.map(\.imp) }

    /// Whether `device` may act for `imp` (ask, stop, fetch files…): only its current holder.
    public func authorises(_ device: UUID, for imp: UUID) -> Bool { holder(of: imp) == device }

    /// The home passes its own Imp to `holder`: a new ticket, and the receiver is the holder.
    public mutating func mint(_ imp: UUID, to holder: UUID) -> Data {
        let ticket = LinkCrypto.mintTicket()
        let generation = (entry(of: imp)?.generation ?? 0) + 1
        entries.removeAll { $0.imp == imp }
        entries.append(Entry(imp: imp, holder: holder, ticket: LinkCrypto.hash(ticket: ticket), generation: generation))
        return ticket
    }

    /// A holder says it has the Imp, with the ticket it was given. A good claim makes it the holder,
    /// rotates the ticket, and queues `gone` for the previous holder.
    public mutating func claim(_ imp: UUID, ticket: Data, by device: UUID) -> Claim {
        guard let i = entries.firstIndex(where: { $0.imp == imp }), LinkCrypto.matches(ticket: ticket, hash: entries[i].ticket) else {
            return .refused
        }
        let previous = entries[i].holder == device ? nil : entries[i].holder
        let fresh = LinkCrypto.mintTicket()
        entries[i].holder = device
        entries[i].ticket = LinkCrypto.hash(ticket: fresh)
        entries[i].generation += 1
        if let previous { tell(previous, imp) }
        return .granted(ticket: fresh, previous: previous)
    }

    /// A holder sends the Imp home with its ticket. True if the ticket was good (the Imp is home now).
    public mutating func release(_ imp: UUID, ticket: Data) -> Bool {
        guard let e = entry(of: imp), LinkCrypto.matches(ticket: ticket, hash: e.ticket) else { return false }
        entries.removeAll { $0.imp == imp }
        return true
    }

    /// The home takes its Imp back at any time: the ticket dies and the holder is told `gone`.
    /// Returns the holder, if it was away.
    @discardableResult
    public mutating func callHome(_ imp: UUID) -> UUID? {
        guard let holder = holder(of: imp) else { return nil }
        entries.removeAll { $0.imp == imp }
        tell(holder, imp)
        return holder
    }

    /// Takes back every Imp `device` holds (it was forgotten). Returns them.
    @discardableResult
    public mutating func callHome(from device: UUID) -> [UUID] {
        held(by: device).filter { callHome($0) != nil }
    }

    /// The Imp came home by itself (passed to its home): its ticket dies and nobody is told.
    public mutating func cameHome(_ imp: UUID) {
        entries.removeAll { $0.imp == imp }
    }

    /// What `device` has to be told, now that it is connected. They are forgotten once taken.
    public mutating func takeNotices(for device: UUID) -> [UUID] {
        let mine = notices.filter { $0.device == device }.map(\.imp)
        notices.removeAll { $0.device == device }
        return mine
    }

    /// Stops owing `device` any news (it was forgotten).
    public mutating func dropNotices(for device: UUID) {
        notices.removeAll { $0.device == device }
    }

    private mutating func tell(_ device: UUID, _ imp: UUID) {
        let notice = Notice(device: device, imp: imp)
        if !notices.contains(notice) { notices.append(notice) }
    }
}
