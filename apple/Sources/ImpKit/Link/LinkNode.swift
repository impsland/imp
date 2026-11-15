import ImpCore
import Foundation
import Network
import Observation
import os

/// A device's part in Imp Link (see `docs/connecting/link.md`). The rules live in `imp-engine`'s node. This
/// is its adapter: it listens, advertises and browses with Network.framework, opens the connections the
/// node asks for, carries bytes both ways, keeps the book where only this user can read it and feeds
/// the node the time. What the node says happened comes out as `Event`s.
///
/// Everything here runs on the main actor.
@MainActor
public final class LinkNode {
    public struct Options: Sendable {
        /// The port to listen on. Another one if it's taken. Nil: any port.
        public var port: UInt16? = LinkProtocol.port
        /// Advertise and browse with Bonjour.
        public var bonjour = true
        /// Watch the network, to redial and republish addresses when it changes.
        public var watchesNetwork = true
        /// The host names and addresses this device gives out. Nil: find them.
        public var hosts: [String]?
        /// The node's timings and limits.
        public var core = linkDefaultOptions()
        /// How often the node is given the time (seconds).
        public var tick: TimeInterval = 0.5

        public init() {}
    }

    public struct Passed: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case took
            case declined(LinkDecline)
        }
        public var transfer: UUID
        public var imp: UUID
        public var to: UUID
        public var isAdoption: Bool
        public var outcome: Outcome
    }

    public enum Problem: Sendable, Equatable {
        case listener(String)
        case storage(String)
        case refused(UUID)
        case keyChanged(UUID)
        case hop
        case inviteRefused(UUID)
        case full(String)
    }

    public enum Event: Sendable {
        case connected(LinkDevice, LinkStanding)
        case disconnected(UUID)
        case linked(LinkDevice)
        case forgotten(UUID, Forgotten)
        case message(LinkMessage, from: UUID)
        case passed(Passed)
        case problem(Problem)
    }

    /// Why the book could not be opened.
    public enum OpenError: Error, Equatable, LocalizedError {
        /// The storage can't be read right now (the Keychain is closed before the first unlock): try again later.
        case unavailable(String)
        /// A book is saved but the core can't decode it.
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .unreadable: "The saved links can't be read."
            }
        }
    }

    public enum JoinError: Error, Equatable {
        case notRunning
        case itsOwnCode
        case keyChanged
        case full
        case unreachable
        case refused
        case timedOut
    }

    public struct Forgotten: Sendable, Equatable {
        public var calledHome: [UUID] = []
        public var sentHome: [UUID] = []

        public init(calledHome: [UUID] = [], sentHome: [UUID] = []) {
            self.calledHome = calledHome; self.sentHome = sentHome
        }
    }

    // MARK: State

    public var onEvent: (@MainActor (Event) -> Void)?
    public let options: Options
    let core: LinkCore
    let storage: LinkStorage
    var running = false { didSet { status.running = running } }
    /// What the app watches: the routes codes carry, whether the node is reachable, whether iOS or macOS
    /// is keeping it off the local network.
    public let status = LinkStatus()
    /// Set while `start()` is under way, so a second caller waits for the same start.
    var starting: Once<Void>?
    var hosts: [String] = []
    var sockets: [UInt64: LinkSocket] = [:]
    var joins: [UUID: CheckedContinuation<Result<LinkDevice, JoinError>, Never>] = [:]
    var dials: [UUID: Task<Void, Never>] = [:]

    var listener: NWListener?
    var listenerGeneration = 0
    var triedFixedPort = false
    var listening: Once<UInt16?>?
    public internal(set) var port: UInt16? { didSet { status.routes.port = port } }
    var browser: NWBrowser?
    var found: [UUID: NWEndpoint] = [:]
    var monitor: NWPathMonitor?
    var hopTask: Task<Void, Never>?
    var housekeeping: Task<Void, Never>?

    let log = Logger(subsystem: "app.imp.Imp", category: "link")

    public init(name: String, kind: LinkKind, id: UUID? = nil, storage: LinkStorage, options: Options = Options()) throws {
        self.storage = storage
        self.options = options
        var core = options.core
        core.port = options.port ?? 0
        let saved: Data?
        do { saved = try storage.load() } catch { throw OpenError.unavailable(error.localizedDescription) }
        do {
            self.core = try LinkCore(saved: saved, name: name, kind: kind.rawValue, id: (id ?? UUID()).uuidString, options: core)
        } catch {
            throw OpenError.unreadable
        }
        if let hosts = options.hosts { setHosts(hosts) }
        apply(self.core.steps())
    }

    /// Opens the node. A saved book the core can't decode is erased and a fresh node made (`reset` is
    /// true then: the links are gone). A storage that can't be read right now throws `OpenError.unavailable`
    /// and nothing is touched.
    public static func open(name: String, kind: LinkKind, id: UUID? = nil, storage: LinkStorage, options: Options = Options()) throws -> (node: LinkNode, reset: Bool) {
        do {
            return (try LinkNode(name: name, kind: kind, id: id, storage: storage, options: options), false)
        } catch OpenError.unreadable {
            Logger(subsystem: "app.imp.Imp", category: "link").error("the link book can't be decoded: erased, starting fresh")
            try storage.erase()
            return (try LinkNode(name: name, kind: kind, id: id, storage: storage, options: options), true)
        }
    }

    // MARK: What the app can ask

    var now: Double { Date().timeIntervalSince1970 }

    public var device: LinkDevice { decode(core.device()) ?? LinkDevice(id: UUID(), name: "", kind: .mac, key: Data(), room: Data()) }
    public var links: [LinkRecord] { decode(core.links()) ?? [] }
    public var visits: Visits { Visits(decode(core.visits()) ?? []) }
    public var away: AwayLedger { AwayLedger(entries: decode(core.away()) ?? []) }
    public var isRunning: Bool { running }
    public var card: LinkCard? { decode(core.card()) }

    public var connected: [UUID] { core.connected().compactMap(UUID.init(uuidString:)) }
    public var connectedPeers: [LinkDevice] { decode(core.connectedPeers()) ?? [] }

    public func standing(of device: UUID) -> LinkStanding? {
        switch try? core.standingOf(device: device.uuidString) {
        case .peer?: .peer
        case .visitor?: .visitor
        case nil: nil
        }
    }

    public func isConnected(_ device: UUID) -> Bool { (try? core.isConnected(device: device.uuidString)) ?? false }
    public func isThroughHop(_ device: UUID) -> Bool { (try? core.isThroughHop(device: device.uuidString)) ?? false }
    public func stage(of device: UUID) -> [LinkStaged] { (try? core.stageOf(device: device.uuidString)).flatMap(decode) ?? [] }
    /// The Imps out on the screens of the owner's other devices (connected, marked Mine here), each at its
    /// own home there. An Imp may message them from wherever it is: those devices let it (`talks::may_ask`).
    public var onMyOtherDevices: [LinkStaged] {
        connected.filter(isTrusted).flatMap { device in stage(of: device).filter { $0.home == device } }
    }
    public func travel(of imp: UUID) -> LinkTravel { (try? core.travelOf(imp: imp.uuidString)).flatMap(decode) ?? .home }
    public func holder(of imp: UUID) -> UUID? { (try? core.holderOf(imp: imp.uuidString)).flatMap { $0 }.flatMap(UUID.init(uuidString:)) }
    public func held(by device: UUID) -> [UUID] { ((try? core.heldBy(device: device.uuidString)) ?? []).compactMap(UUID.init(uuidString:)) }

    public func door(of imp: UUID, side: LinkSide, height: Double) -> LinkDoors.Outcome {
        guard let door = try? core.doorOf(imp: imp.uuidString, side: side.rawValue, height: height) else { return .bounce(.nobodyConnected) }
        if let id = door.device.flatMap(UUID.init(uuidString:)) { return .to(id) }
        switch door.bounce {
        case .wayBackIsClosed?: return .bounce(.wayBackIsClosed)
        case .nowhereElse?: return .bounce(.nowhereElse)
        default: return .bounce(.nobodyConnected)
        }
    }

    public func bands(of imp: UUID, side: LinkSide) -> [LinkDoors.Band] {
        ((try? core.bandsOf(imp: imp.uuidString, side: side.rawValue)) ?? []).compactMap { band in
            UUID(uuidString: band.device).map { LinkDoors.Band(device: $0, top: band.top, bottom: band.bottom) }
        }
    }

    public func setTrusted(_ device: UUID, _ on: Bool) {
        if let steps = try? core.setTrusted(device: device.uuidString, on: on) { apply(steps) }
    }

    public func isTrusted(_ device: UUID) -> Bool { (try? core.isTrusted(device: device.uuidString)) ?? false }

    public func isTrusted(_ message: LinkMessage, from device: UUID) -> Bool {
        guard let text = encode(message) else { return false }
        return (try? core.isTrustedMessage(message: text, device: device.uuidString)) ?? false
    }

    public func rename(_ name: String) { core.rename(name: name) }

    // MARK: Sending

    @discardableResult
    public func send(_ message: LinkMessage, to device: UUID) -> Bool {
        guard let text = encode(message), let out = try? core.send(message: text, to: device.uuidString) else { return false }
        apply(out.steps)
        return out.ok
    }

    /// Sends and waits until the bytes have left, so a long stream of parts does not pile up in memory.
    @discardableResult
    public func sendAndWait(_ message: LinkMessage, to device: UUID) async -> Bool {
        guard let text = encode(message), let out = try? core.send(message: text, to: device.uuidString), out.ok else { return false }
        let used = out.steps.compactMap { step -> LinkSocket? in
            if case .send(let conn, _) = step { return sockets[conn] }
            return nil
        }
        apply(out.steps)
        for socket in used { if await !socket.drained() { return false } }
        return true
    }

    public func invite() -> LinkInvite? {
        LinkInvite(info: core.invite(now: now))
    }

    public func inviteHidden() { core.inviteHidden(now: now) }

    public func join(_ invite: LinkInvite) async throws -> LinkDevice {
        // A node that isn't up (or is still coming up) is started and waited for first.
        await start()
        let id = invite.device.id
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<LinkDevice, JoinError>, Never>) in
            joins[id]?.resume(returning: .failure(.refused))
            joins[id] = done
            do { apply(try core.join(invite: invite.url.absoluteString, now: now)) } catch {
                joins[id] = nil
                done.resume(returning: .failure(.refused))
            }
        }
        return try result.get()
    }

    public func forget(_ device: UUID) -> Forgotten {
        guard let steps = try? core.forget(device: device.uuidString, now: now) else { return Forgotten() }
        return apply(steps)
    }

    public func forgetEveryone() -> Forgotten { apply(core.forgetEveryone(now: now)) }

    public func setServer(_ address: String?) {
        status.routes.hop = address
        apply(core.setServer(address: address).steps)
    }

    public func setStage(_ imps: [LinkStaged]) {
        guard let text = encode(imps), let steps = try? core.setStage(imps: text) else { return }
        apply(steps)
    }

    public func pass(_ imp: LinkImp, entry: LinkEntry, to device: UUID) -> UUID? {
        guard let imp = encode(imp), let entry = encode(entry), let out = try? core.pass(imp: imp, entry: entry, to: device.uuidString, now: now) else { return nil }
        apply(out.steps)
        return out.id.flatMap(UUID.init(uuidString:))
    }

    public func adopt(_ imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry, to device: UUID) -> UUID? {
        guard let secrets = encode(secrets), let entry = encode(entry),
              let out = try? core.adopt(imp: imp.uuidString, kit: kit, secrets: secrets, entry: entry, to: device.uuidString, now: now) else { return nil }
        apply(out.steps)
        return out.id.flatMap(UUID.init(uuidString:))
    }

    public func canAccept(_ transfer: UUID) -> Bool { (try? core.canAccept(transfer: transfer.uuidString)) ?? false }

    public func accept(_ transfer: UUID) -> Bool {
        guard let out = try? core.accept(transfer: transfer.uuidString, now: now) else { return false }
        apply(out.steps)
        return out.ok
    }

    public func decline(_ transfer: UUID, reason: LinkDecline) {
        if let steps = try? core.decline(transfer: transfer.uuidString, reason: reason.rawValue) { apply(steps) }
    }

    @discardableResult
    public func callHome(_ imp: UUID) -> UUID? {
        guard let out = try? core.callHome(imp: imp.uuidString) else { return nil }
        apply(out.steps)
        return out.id.flatMap(UUID.init(uuidString:))
    }

    public func sendHome(_ imp: UUID) -> Bool {
        guard let out = try? core.sendHome(imp: imp.uuidString, now: now) else { return false }
        apply(out.steps)
        return out.ok
    }

    public enum First: Sendable, Equatable {
        case here
        case via(UUID)
        case unreachable
    }

    /// An Imp of this device asks another. Where the question goes first.
    public func talk(id: UUID, from: LinkImp, to: UUID, toHome: UUID, text: String, holder: UUID) -> First {
        guard let imp = encode(from) else { return .unreachable }
        let question = LinkQuestion(id: id.uuidString, from: imp, to: to.uuidString, toHome: toHome.uuidString, text: text, holder: holder.uuidString)
        guard let talk = try? core.talk(question: question, now: now) else { return .unreachable }
        apply(talk.steps)
        switch talk.first {
        case .here: return .here
        case .via(let device): return UUID(uuidString: device).map { .via($0) } ?? .unreachable
        case .unreachable: return .unreachable
        }
    }

    // MARK: Steps

    func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder.link.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    func decode<T: Decodable>(_ text: String) -> T? {
        try? JSONDecoder.link.decode(T.self, from: Data(text.utf8))
    }

    @discardableResult
    func apply(_ steps: [LinkStep]) -> Forgotten {
        var forgotten = Forgotten()
        for step in steps {
            switch step {
            case .send(let conn, let bytes):
                sockets[conn]?.send(bytes)
            case .close(let conn):
                sockets.removeValue(forKey: conn)?.cancel()
            case .dial(let device, let card):
                if let id = UUID(uuidString: device), let card: LinkCard = decode(card) { dial(id, card) }
            case .save(let bytes):
                do { try storage.save(bytes) } catch {
                    log.error("couldn't save the link book: \(String(describing: error), privacy: .public)")
                    apply(core.saveFailed(reason: error.localizedDescription))
                }
            case .relisten:
                if running { startListener(fixed: options.port) }
            case .hopChanged:
                restartHop()
            case .connected(let device, let standing):
                if let device: LinkDevice = decode(device) { emit(.connected(device, standing == .peer ? .peer : .visitor)) }
            case .disconnected(let device):
                if let id = UUID(uuidString: device) { emit(.disconnected(id)) }
            case .linked(let device):
                if let device: LinkDevice = decode(device) { emit(.linked(device)) }
            case .forgotten(let device, let calledHome, let sentHome):
                let f = Forgotten(calledHome: calledHome.compactMap(UUID.init(uuidString:)), sentHome: sentHome.compactMap(UUID.init(uuidString:)))
                forgotten.calledHome += f.calledHome
                forgotten.sentHome += f.sentHome
                if let id = UUID(uuidString: device) { emit(.forgotten(id, f)) }
            case .message(let text, let from):
                if let message: LinkMessage = decode(text), let id = UUID(uuidString: from) { emit(.message(message, from: id)) }
            case .passed(let transfer, let imp, let to, let adopt, let took, let decline):
                if let transfer = UUID(uuidString: transfer), let imp = UUID(uuidString: imp), let to = UUID(uuidString: to) {
                    let reason = decline.flatMap { LinkDecline(rawValue: $0) } ?? .other
                    emit(.passed(Passed(transfer: transfer, imp: imp, to: to, isAdoption: adopt, outcome: took ? .took : .declined(reason))))
                }
            case .joined(let device, let linked, let failure):
                guard let id = UUID(uuidString: device), let waiting = joins.removeValue(forKey: id) else { continue }
                if linked, let device = links.first(where: { $0.id == id })?.device { waiting.resume(returning: .success(device)) } else {
                    waiting.resume(returning: .failure(Self.joinError(failure)))
                }
            case .problem(let problem):
                emit(.problem(Self.problem(problem)))
            }
        }
        return forgotten
    }

    func emit(_ event: Event) { onEvent?(event) }

    private static func joinError(_ failure: LinkJoinFailure?) -> JoinError {
        switch failure {
        case .notRunning?: .notRunning
        case .itsOwnCode?: .itsOwnCode
        case .keyChanged?: .keyChanged
        case .full?: .full
        case .refused?: .refused
        case .timedOut?: .timedOut
        default: .unreachable
        }
    }

    private static func problem(_ problem: LinkTrouble) -> Problem {
        switch problem {
        case .listener(let reason): .listener(reason)
        case .storage(let reason): .storage(reason)
        case .refused(let device): UUID(uuidString: device).map { .refused($0) } ?? .hop
        case .keyChanged(let device): UUID(uuidString: device).map { .keyChanged($0) } ?? .hop
        case .hop: .hop
        case .inviteRefused(let device): UUID(uuidString: device).map { .inviteRefused($0) } ?? .hop
        case .full(let what): .full(what)
        }
    }

    // MARK: Addresses

    /// Interface names of VPN tunnels and of bridges for virtual machines. Their addresses go last in a
    /// code, because a phone on the same Wi-Fi can't reach them. The command line app orders its
    /// addresses the same way (`order_hosts` in chat/src/link.rs).
    nonisolated static let farInterfaces = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "gif", "stf", "bridge", "vmenet", "vnic"]

    /// Where other devices can reach this one, best first: the .local name, then the addresses of Wi-Fi
    /// and Ethernet, then those of VPN tunnels and virtual machine bridges.
    nonisolated static func localHosts() -> [String] {
        var addresses: [(interface: String, address: String, pointToPoint: Bool)] = []
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
                // Link-local addresses (169.254...) are no use to anyone else.
                guard !address.hasPrefix("169.254.") else { continue }
                addresses.append((String(cString: i.ifa_name), address, Int32(i.ifa_flags) & IFF_POINTOPOINT != 0))
            }
        }
        return orderHosts(localName: ProcessInfo.processInfo.hostName, addresses: addresses)
    }

    /// Orders what `localHosts` found: the .local name first, then the near addresses in the order the
    /// system lists them, then the far ones (see `farInterfaces`), without repeats.
    nonisolated static func orderHosts(localName: String, addresses: [(interface: String, address: String, pointToPoint: Bool)]) -> [String] {
        var names: [String] = []
        let host = localName.lowercased()
        if host.hasSuffix(".local") { names.append(host) }
        let isFar = { (entry: (interface: String, address: String, pointToPoint: Bool)) in
            entry.pointToPoint || farInterfaces.contains { entry.interface.hasPrefix($0) }
        }
        let near = addresses.filter { !isFar($0) }.map(\.address)
        let far = addresses.filter(isFar).map(\.address)
        for address in near + far where !names.contains(address) { names.append(address) }
        return names
    }
}

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

/// What a `LinkNode` lets the app watch (observable).
@MainActor @Observable
public final class LinkStatus {
    /// Where other devices can reach this one: what a code carries.
    public struct Routes: Equatable, Hashable, Sendable {
        public var hosts: [String] = []
        public var port: UInt16?
        /// The Hop (Imp server) this device waits at.
        public var hop: String?

        /// A code made from these has a way to the device: local addresses and a port, or a Hop.
        public var canBeReached: Bool { (port != nil && !hosts.isEmpty) || hop != nil }
    }

    public internal(set) var routes = Routes()
    public internal(set) var running = false
    /// Local Network access is off for the app: nothing on the local network can find or reach it.
    public internal(set) var localNetworkBlocked = false

    /// Up, with a way to reach it: only then is a code worth showing.
    public var isReady: Bool { running && routes.canBeReached }
}
