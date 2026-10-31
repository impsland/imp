import Foundation
import Network
import os

/// A device's whole part in Imp Link 2 (see `docs/LINK.md`): it listens and advertises, dials the
/// devices it is linked to and the homes of the Imps it holds, runs the handshake, and keeps the
/// book, the away ledger and the visits. The app above it decides what an Imp does; the node decides
/// who may talk to whom, and tells the app what happened.
///
/// Everything here runs on the main actor. The sockets live in `LinkChannel`, which hands each
/// connection's life over as an ordered stream.
@MainActor
public final class LinkNode {
    public struct Options: Sendable {
        /// The port to listen on; another one if it's taken. Nil: any port.
        public var port: UInt16? = LinkProtocol.port
        /// Advertise and browse with Bonjour.
        public var bonjour = true
        /// Watch the network, to redial and republish addresses when it changes.
        public var watchesNetwork = true
        /// The host names and addresses this device gives out. Nil: find them.
        public var hosts: [String]?
        public var pingInterval = LinkProtocol.pingInterval
        public var silenceLimit = LinkProtocol.silenceLimit
        public var visitorGrace = LinkProtocol.visitorGrace
        /// How long an invite works after its code was last on screen.
        public var inviteLife = LinkProtocol.inviteLife
        /// How long a connection may take to finish its handshake.
        public var handshakeTimeout: TimeInterval = 10
        public var transferTimeout = LinkProtocol.transferTimeout
        public var answerTimeout = LinkProtocol.answerTimeout
        /// How long to wait before redialling a device that can't be reached, doubling up to the longest.
        public var retryStart: TimeInterval = 1
        public var retryLongest: TimeInterval = 60
        /// How long `join` waits for the host.
        public var joinTimeout: TimeInterval = 30
        /// How often timeouts are looked at.
        public var tick: TimeInterval = 0.5
        /// How many frames a connection may send per second, and in one burst; more closes it.
        public var frameRate: Double = 100
        public var frameBurst: Double = 400

        public init() {}
    }

    /// An Imp that was thrown, and how it ended.
    public struct Passed: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case took
            case declined(LinkDecline)
        }
        public var transfer: UUID
        public var imp: UUID
        public var to: UUID
        public var kind: Transfers.Kind
        public var outcome: Outcome
    }

    /// Something that went wrong that a person may want to hear about. Never carries secrets.
    public enum Problem: Sendable, Equatable {
        case listener(String)
        case storage(String)
        /// The device answered but TLS refused: it doesn't share our door key (it forgot everyone).
        case refused(UUID)
        /// The device presented another key than the one pinned for it.
        case keyChanged(UUID)
        /// The device's proof for this connection was wrong.
        case badProof(UUID?)
        /// The Hop turned this device's room away.
        case hop
        /// A code was refused: it expired, or the host forgot it.
        case inviteRefused(UUID)
        /// A limit (links, visits, connections) was hit.
        case full(String)
    }

    public enum Event: Sendable {
        /// A handshake finished: the device is connected, as a peer or a visitor.
        case connected(LinkDevice, LinkStanding)
        case disconnected(UUID)
        /// A link was made (a device scanned our code, or we scanned its).
        case linked(LinkDevice)
        /// The other side forgot us: the link is gone on this side too, our Imps it held are called home
        /// and the Imps of its that visited us are sent home (the app removes those bodies).
        case forgotten(UUID, Forgotten)
        /// A message the node didn't deal with itself, from a device allowed to send it. `stage`,
        /// `claim` and `release` arrive after the node updated its books.
        case message(LinkMessage, from: UUID)
        /// A thrown Imp was answered or timed out.
        case passed(Passed)
        case problem(Problem)
    }

    public enum JoinError: Error, Equatable {
        case notRunning
        case itsOwnCode
        /// The device is already linked with another key.
        case keyChanged
        case full
        /// No route to the host worked.
        case unreachable
        /// The host answered but would not link (the code expired, or was replaced).
        case refused
        case timedOut
    }

    /// What `forget` did to the Imps involved, for the app to show.
    public struct Forgotten: Sendable, Equatable {
        /// Imps of this device the forgotten device held, taken back home.
        public var calledHome: [UUID] = []
        /// Imps visiting this device whose home was forgotten: they go home, so their bodies go.
        public var sentHome: [UUID] = []

        public init(calledHome: [UUID] = [], sentHome: [UUID] = []) {
            self.calledHome = calledHome; self.sentHome = sentHome
        }
    }

    // MARK: State

    public var onEvent: (@MainActor (Event) -> Void)?
    public let options: Options
    let storage: LinkStorage
    var identity: LinkIdentity
    var book: LinkBook
    var running = false
    var inviteOnScreen = false
    var transfers = Transfers()
    var talks = LinkTalks.Pending()
    var stages: [UUID: [LinkStaged]] = [:]
    var ownStage: [LinkStaged] = []
    var arrivals: [UUID: Arrival] = [:]
    var hop: HopAddress?
    var published: [UUID: LinkRoutes] = [:]
    var hosts: [String] = []

    var sessions: Set<Session> = []
    var connections: [UUID: Session] = [:]

    var listener: NWListener?
    var listenerGeneration = 0
    var triedFixedPort = false
    var listening: Once<UInt16?>?
    public internal(set) var port: UInt16?
    var browser: NWBrowser?
    var found: [UUID: NWEndpoint] = [:]
    var monitor: NWPathMonitor?
    var hopHost: HopHost?
    var notes: AsyncStream<Note>.Continuation?
    var noteTask: Task<Void, Never>?
    var housekeeping: Task<Void, Never>?

    var dials: [UUID: Dial] = [:]
    var delays: [UUID: TimeInterval] = [:]
    /// Devices whose refusal was already reported, so a retry doesn't repeat it.
    var reported: Set<UUID> = []
    var joins: [UUID: Join] = [:]

    let log = Logger(subsystem: "app.imp.Imp", category: "link")

    /// A node for this device. The book is loaded from `storage`, or made (with a fresh key) on the
    /// first run; `id` only matters then. Throws when a book exists but can't be read.
    public init(name: String, kind: LinkKind, id: UUID? = nil, storage: LinkStorage, options: Options = Options()) throws {
        self.storage = storage
        self.options = options
        if let saved = try storage.load() {
            guard let identity = LinkIdentity(id: saved.device, name: name, kind: kind, seed: saved.seed) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.identity = identity
            book = saved
        } else {
            let fresh = LinkIdentity(id: id ?? UUID(), name: name, kind: kind)
            identity = fresh
            book = LinkBook(device: fresh.id, seed: fresh.seed, door: LinkCrypto.randomKey())
            try storage.save(book)
        }
        hosts = options.hosts ?? Self.localHosts()
    }

    // MARK: What the app can ask

    /// This device, as others see it.
    public var device: LinkDevice { identity.device }
    public var links: [LinkRecord] { book.links }
    public var visits: Visits { book.visits }
    public var away: AwayLedger { book.away }
    /// Whether this node is up (started and not stopped).
    public var isRunning: Bool { running }

    /// Every connected device, linked or not.
    public var connected: [UUID] { Array(connections.keys) }

    /// The connected devices an Imp can be thrown to.
    public var connectedPeers: [LinkDevice] {
        connections.values.filter { $0.standing == .peer }.compactMap(\.remote)
    }

    public func standing(of device: UUID) -> LinkStanding? { connections[device]?.standing }
    public func isConnected(_ device: UUID) -> Bool { connections[device] != nil }
    public func isThroughHop(_ device: UUID) -> Bool { connections[device]?.channel.isThroughHop ?? false }

    /// The Imps a device said are on its screen.
    public func stage(of device: UUID) -> [LinkStaged] { stages[device] ?? [] }

    /// How an Imp got to this screen.
    public func travel(of imp: UUID) -> LinkTravel { book.visits.travel(of: imp) }

    /// Where the Imp goes when thrown off `side` at `height` of this screen.
    public func door(of imp: UUID, side: LinkSide, height: Double) -> LinkDoors.Outcome {
        LinkDoors.door(side: side, height: height, travel: travel(of: imp), connected: connectedPeers.map(\.id))
    }

    /// The bands of a side, for labelling, while an Imp is carried near it.
    public func bands(of imp: UUID, side: LinkSide) -> [LinkDoors.Band] {
        LinkDoors.bands(side: side, travel: travel(of: imp), connected: connectedPeers.map(\.id))
    }

    // MARK: Trust

    /// Marks a linked device as one of the owner's own (or not). Visitors and unknown devices can't be.
    public func setTrusted(_ device: UUID, _ on: Bool) {
        guard let i = book.links.firstIndex(where: { $0.id == device }), book.links[i].trusted != on else { return }
        book.links[i].trusted = on
        commit()
    }

    /// Whether a device is linked and marked as one of the owner's own. Nobody else ever is.
    public func isTrusted(_ device: UUID) -> Bool {
        book.links.first { $0.id == device }?.trusted ?? false
    }

    /// Whether what `message` asks of this device comes from a trusted source, which is when its Imp
    /// may use tools to answer. A request of a holder (`ask`, `file`…) is trusted if the holder is. A
    /// question from an Imp is trusted if its home is this device (and `device` holds it) or a trusted
    /// one, and `device` is that home or trusted too. Anything else is not.
    public func isTrusted(_ message: LinkMessage, from device: UUID) -> Bool {
        switch message {
        case .ask, .stop, .newChat, .felt, .file, .talks:
            return isTrusted(device)
        case .message(_, let asker, _, _, _, _):
            guard let home = askerHome(asker.id, via: device) else { return false }
            if home == identity.id { return device == identity.id || book.away.holder(of: asker.id) == device }
            return isTrusted(home) && (device == home || isTrusted(device))
        default:
            return false
        }
    }

    /// The home of an Imp, as `device` (or this device) says it stages it.
    private func askerHome(_ imp: UUID, via device: UUID) -> UUID? {
        (ownStage + (stages[device] ?? [])).first { $0.id == imp }?.home
    }

    /// The device holding one of this device's Imps that is away.
    public func holder(of imp: UUID) -> UUID? { book.away.holder(of: imp) }

    /// This device's own card: what travels with an Imp whose home it is.
    public var card: LinkCard { LinkCard(device: identity.device, door: book.door, routes: currentRoutes()) }

    /// Changes the name other devices see (the new name reaches them when they next connect).
    public func rename(_ name: String) {
        identity.name = LinkDevice.cleaned(name, kind: identity.kind)
    }

    // MARK: Events

    func emit(_ event: Event) { onEvent?(event) }

    /// Saves the book after a change; a failure is a problem to show, the change stays in memory.
    func commit() {
        do { try storage.save(book) } catch {
            log.error("couldn't save the link book: \(String(describing: error), privacy: .public)")
            emit(.problem(.storage(error.localizedDescription)))
        }
    }

    // MARK: Addresses

    func currentRoutes() -> LinkRoutes {
        LinkRoutes(hosts: hosts, port: port ?? options.port ?? LinkProtocol.port, hop: hop?.text)
    }

    /// The host name and IPv4 addresses other devices on this network can try.
    static func localHosts() -> [String] {
        var names: [String] = []
        let host = ProcessInfo.processInfo.hostName.lowercased()
        if host.hasSuffix(".local") { names.append(host) }
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let i = ptr.pointee
                guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                      Int32(i.ifa_flags) & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == (IFF_UP | IFF_RUNNING) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                // Link-local addresses (169.254…) are no use to anyone else.
                if !address.hasPrefix("169.254.") { names.append(address) }
            }
        }
        return names
    }
}

/// Something that happens once, which any number of tasks can wait for.
@MainActor
final class Once<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    var isDone: Bool { value != nil }

    func fulfil(_ v: Value) {
        guard value == nil else { return }
        value = v
        waiters.forEach { $0.resume(returning: v) }
        waiters = []
    }

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Things the network tells the node, in order.
enum Note: Sendable {
    case accepted(NWConnection)
    case listening(generation: Int, port: UInt16)
    case listenerFailed(generation: Int, String)
    case found([UUID: NWEndpoint])
    case path
}

/// An Imp (or one that wants to move in) that was thrown here and waits for the app's answer.
struct Arrival {
    enum Kind {
        case pass(imp: LinkImp, entry: LinkEntry, home: LinkCard?, ticket: Data?)
        case adopt
    }
    var transfer: UUID
    var from: UUID
    var imp: UUID
    var kind: Kind
}

/// A device to dial, and the invite key if this is a join.
struct DialTarget {
    var card: LinkCard
    var join: Data?
    var id: UUID { card.id }
}

@MainActor
final class Dial {
    var cancelled = false
    var wake: Once<Void>?
}

@MainActor
final class Join {
    let invite: LinkInvite
    let result = Once<Result<LinkDevice, LinkNode.JoinError>>()
    init(_ invite: LinkInvite) { self.invite = invite }
}
