import Foundation

/// Bookkeeping for Imps in flight (see "Passing" in `docs/LINK.md`). A throw is answered `took` or
/// `declined`; no answer in time is a decline. A transfer id that comes again is answered again and
/// never taken twice. Pure: time is passed in.
public struct Transfers: Sendable {
    public enum Kind: Sendable, Equatable {
        case pass
        /// Moving in for good waits for the receiver's user, so it gets longer.
        case adopt
    }

    /// A throw this device made and waits to hear about.
    public struct Outgoing: Sendable, Equatable {
        public var id: UUID
        public var imp: UUID
        public var to: UUID
        public var kind: Kind
        var deadline: Date
    }

    /// What this device answered (or still owes) for a throw it received.
    public enum Reply: Sendable, Equatable {
        case waiting
        case took
        case declined(LinkDecline)
    }

    /// How long a receiver may take to answer an `adopt`.
    public static let adoptTimeout: TimeInterval = 10 * 60
    /// How many answers are remembered for repeats.
    static let remembered = 256

    public private(set) var outgoing: [UUID: Outgoing] = [:]
    private var incoming: [UUID: (from: UUID, reply: Reply, deadline: Date)] = [:]
    private var order: [UUID] = []

    public init() {}

    // MARK: Throwing

    /// A throw was sent to `to`.
    public mutating func sent(_ id: UUID, imp: UUID, to: UUID, kind: Kind = .pass, now: Date = Date(),
                              timeout: TimeInterval = LinkProtocol.transferTimeout) {
        let wait = kind == .adopt ? max(timeout, Self.adoptTimeout) : timeout
        outgoing[id] = Outgoing(id: id, imp: imp, to: to, kind: kind, deadline: now.addingTimeInterval(wait))
    }

    /// `took` or `declined` came from `device`. Nil if nothing was waiting for that from it (an
    /// unknown id, a late answer after the timeout, or somebody else's).
    public mutating func answered(_ id: UUID, by device: UUID) -> Outgoing? {
        guard let t = outgoing[id], t.to == device else { return nil }
        outgoing[id] = nil
        return t
    }

    /// The throws that ran out of time.
    public mutating func expired(now: Date = Date()) -> [Outgoing] {
        let late = outgoing.values.filter { $0.deadline <= now }
        late.forEach { outgoing[$0.id] = nil }
        return late
    }

    /// The throws to `device`, which just went away.
    public mutating func lost(_ device: UUID) -> [Outgoing] {
        let gone = outgoing.values.filter { $0.to == device }
        gone.forEach { outgoing[$0.id] = nil }
        return gone
    }

    // MARK: Catching

    public enum Received: Sendable, Equatable {
        /// First time: ask the user (or the screen) and answer with `answer`.
        case new
        /// Already asked and still waiting: say nothing.
        case pending
        /// Already answered: answer the same again.
        case repeated(Reply)
    }

    /// A throw arrived from `device`.
    public mutating func received(_ id: UUID, from device: UUID, now: Date = Date(),
                                  timeout: TimeInterval = LinkProtocol.transferTimeout) -> Received {
        if let known = incoming[id], known.from == device {
            return known.reply == .waiting ? .pending : .repeated(known.reply)
        }
        incoming[id] = (device, .waiting, now.addingTimeInterval(timeout))
        order.append(id)
        if order.count > Self.remembered { incoming[order.removeFirst()] = nil }
        return .new
    }

    /// Whether a throw was received and is still waiting for an answer.
    public func isWaiting(_ id: UUID) -> Bool { incoming[id]?.reply == .waiting }

    /// Records the answer to a throw. False if it is not one waiting (answered already, or unknown).
    @discardableResult
    public mutating func answer(_ id: UUID, _ reply: Reply) -> Bool {
        guard var known = incoming[id], known.reply == .waiting else { return false }
        known.reply = reply
        incoming[id] = known
        return true
    }

    /// Throws nobody answered in time: they were declined (the thrower gave up on them anyway).
    public mutating func lapsed(now: Date = Date()) -> [(id: UUID, from: UUID)] {
        let late = incoming.filter { $0.value.reply == .waiting && $0.value.deadline <= now }
        for (id, _) in late { incoming[id]?.reply = .declined(.timeout) }
        return late.map { ($0.key, $0.value.from) }
    }
}
