import AppKit
import ImpKit
import Network
import Observation
import os

/// The Mac's side of Imp Link: the iPhones an Imp can be tossed onto.
///
/// Pairing makes a secret (kept in a private file in Imp's folder, like API keys) and shows it as
/// a QR code. From then on the Mac listens, on the local network and by Bonjour, for phones that
/// hold the same secret (TLS with a pre-shared key: nobody else gets past the handshake).
///
/// An Imp on a phone is still one of the Mac's Imps: its brain, keys, tools and chats stay here.
/// The phone draws it and is its chat; this relays what it's doing (`watch`) and what the phone
/// asks of it. A phone may only talk to the Imps that are on it.
@MainActor @Observable
final class PhoneLink {
    struct Phone: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var lastSeen: Date
    }

    /// What pairing keeps: this Mac's link identity, the secret and the phones that came by.
    private struct Saved: Codable {
        var mac: UUID
        var secret: Data
        var phones: [Phone]
    }

    /// Phones that have connected since pairing was set up.
    private(set) var phones: [Phone] = []
    /// Phones connected right now: id → name.
    private(set) var connected: [UUID: String] = [:]
    /// An iPhone is set up (pairing was opened at least once): the desktop's edges throw.
    private(set) var isSetUp = false
    /// Why the Mac can't listen, if it can't.
    private(set) var problem: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var saved: Saved?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    /// What each phone was last told about each of its Imps (only changes are sent).
    @ObservationIgnored private var sent: [UUID: Snapshot] = [:]
    @ObservationIgnored private var flushing: Set<UUID> = []
    @ObservationIgnored private var lastOthers: [LinkImp] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "app.imp.Imp.link")
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "link")
    @ObservationIgnored private let file: URL

    private final class Peer {
        let channel: LinkChannel
        /// Who it is, once it said hello (nothing else is listened to before).
        var device: UUID?
        var name = ""
        var since = Date()
        init(_ channel: LinkChannel) { self.channel = channel }
    }

    /// What a phone knows about one of its Imps.
    private struct Snapshot: Equatable {
        var look: LinkImp
        var mood: String
        var work: LinkWork?
        var chat: [LinkTurn]
    }

    /// Turns of the current chat a phone is sent (it shows the latest; the Mac keeps them all).
    static let chatPage = 40
    /// Longest message a phone may send.
    static let maxText = 20_000

    init(app: AppModel, file: URL = URL.applicationSupportDirectory.appendingPathComponent("Imp/iphone.json")) {
        self.app = app
        self.file = file
    }

    // MARK: Setting up

    /// Listens if an iPhone was set up before.
    func start() {
        guard app.persists, let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data),
              s.secret.count == LinkPairing.secretBytes else { return }
        saved = s
        phones = s.phones
        isSetUp = true
        listen()
        watchOthers()
    }

    /// The pairing link (and QR code) for a new phone. Sets the link up the first time.
    func pairing() -> LinkPairing {
        if saved == nil {
            saved = Saved(mac: UUID(), secret: LinkPairing.newSecret(), phones: [])
            save()
            isSetUp = true
            listen()
            watchOthers()
        }
        let s = saved!
        return LinkPairing(mac: s.mac, name: Self.macName, secret: s.secret, hosts: Self.hosts(),
                           port: listener?.port?.rawValue ?? LinkProtocol.port)
    }

    /// Forgets every phone: a new secret, so old pairing codes stop working, and every Imp on a
    /// phone comes back to the desktop.
    func forgetPhones() {
        for (id, profile) in app.prefs.imps.map({ ($0.id, $0) }) where profile.awayOn != nil {
            app.cameBack(id, entry: LinkEntry(side: .right, height: 0.5, speed: 0))
        }
        peers.values.forEach { $0.channel.close() }
        peers = [:]
        connected = [:]
        phones = []
        sent = [:]
        listener?.cancel()
        listener = nil
        saved = nil
        isSetUp = false
        problem = nil
        try? FileManager.default.removeItem(at: file)
    }

    /// The phone an Imp tossed now lands on: the one that spoke last.
    var nearestPhone: UUID? {
        peers.values.filter { $0.device != nil }.max { $0.since < $1.since }?.device
    }

    var isConnected: Bool { !connected.isEmpty }

    func name(of phone: UUID) -> String? { connected[phone] ?? phones.first { $0.id == phone }?.name }

    private func save() {
        guard var s = saved else { return }
        s.phones = phones
        saved = s
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(s)
            // Private from the start, like the key file: the secret lets a phone in.
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try data.write(to: file)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            log.error("couldn't save the iPhone link: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Listening

    private func listen() {
        guard listener == nil, let s = saved else { return }
        let params = LinkTLS.parameters(psk: LinkPairing.psk(for: s.secret))
        params.allowLocalEndpointReuse = true
        // The fixed port first (so a phone can dial it by address); any port if that one's taken.
        let l: NWListener
        if let fixed = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: LinkProtocol.port)!) {
            l = fixed
        } else if let any = try? NWListener(using: params) {
            l = any
        } else {
            problem = String(localized: "Imp can't listen for your iPhone on this network.")
            return
        }
        l.service = NWListener.Service(name: Self.macName, type: LinkProtocol.serviceType, domain: nil,
                                       txtRecord: NWTXTRecord(["mac": s.mac.uuidString]))
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.accept(c) }
        }
        l.stateUpdateHandler = { [weak self, log] state in
            switch state {
            case .failed(let e):
                log.error("link listener failed: \(e.localizedDescription, privacy: .public)")
                Task { @MainActor in self?.relisten() }
            case .ready:
                Task { @MainActor in self?.problem = nil }
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    /// The network changed under the listener: start over in a moment.
    private func relisten() {
        listener?.cancel()
        listener = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.listen()
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = LinkChannel(connection: connection)
        let peer = Peer(channel)
        let id = channel.id
        peers[id] = peer
        channel.onFrame = { [weak self] body in
            guard let request = LinkFrame.decode(LinkRequest.self, body) else { return }
            Task { @MainActor in self?.handle(request, from: id) }
        }
        channel.onState = { [weak self] state in
            guard case .closed(let reason) = state else { return }
            Task { @MainActor in self?.dropped(id, reason: reason) }
        }
        channel.start()
    }

    private func dropped(_ id: UUID, reason: String?) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        if let device = peer.device, !peers.values.contains(where: { $0.device == device }) {
            connected[device] = nil
            log.info("iPhone “\(peer.name, privacy: .public)” left: \(reason ?? "closed", privacy: .public)")
        }
    }

    // MARK: From the phone

    private func handle(_ request: LinkRequest, from id: UUID) {
        guard let peer = peers[id] else { return }
        if case .hello(let device, let name, _) = request { return hello(peer, device: device, name: name) }
        guard let device = peer.device else { return }          // nothing before hello
        peer.since = Date()
        /// Only the Imps on this phone take orders from it.
        func own(_ imp: UUID) -> ImpModel? {
            app.profile(imp)?.awayOn == device ? app.imp(imp) : nil
        }
        switch request {
        case .hello: break
        case .ping:
            peer.channel.send(LinkUpdate.pong)
        case .ask(let imp, let text):
            let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxText))
            guard let model = own(imp), !words.isEmpty else { return }
            model.ask(words)
        case .stop(let imp):
            own(imp)?.cancel()
        case .newChat(let imp):
            own(imp)?.newChat()
        case .toss(let imp, let exit, let height, let speed):
            guard own(imp) != nil else { return peer.channel.send(LinkUpdate.leave(imp: imp)) }
            app.cameBack(imp, entry: .after(exit: exit, height: height, speed: speed))
        case .felt(let imp, let feeling):
            guard let model = own(imp) else { return }
            let trigger: AnimationTrigger = switch feeling {
            case .poke: .poke
            case .cuddle: .hold
            case .shake: .shake
            case .drop: .drop
            }
            app.reactions.play(trigger, by: model)
        }
    }

    private func hello(_ peer: Peer, device: UUID, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        peer.device = device
        peer.name = name.isEmpty ? String(localized: "iPhone") : name
        peer.since = Date()
        connected[device] = peer.name
        if let i = phones.firstIndex(where: { $0.id == device }) {
            phones[i].name = peer.name
            phones[i].lastSeen = Date()
        } else {
            phones.append(Phone(id: device, name: peer.name, lastSeen: Date()))
        }
        save()
        log.info("iPhone “\(peer.name, privacy: .public)” is here")
        let mine = app.prefs.imps.filter { $0.isActive && $0.awayOn == device }
        peer.channel.send(LinkUpdate.welcome(mac: Self.macName, version: LinkProtocol.version,
                                             imps: mine.map(LinkImp.init), others: others()))
        // Everything about them, fresh.
        for p in mine {
            sent[p.id] = nil
            watch(p.id)
        }
    }

    // MARK: To the phone

    /// Sends an Imp to the phone. False when no phone is around.
    func send(_ id: UUID, entry: LinkEntry) -> Bool {
        guard let device = nearestPhone, let profile = app.profile(id) else { return false }
        channels(for: device).forEach { $0.send(LinkUpdate.arrive(imp: LinkImp(profile), entry: entry)) }
        return true
    }

    /// Tells the phone its Imp has gone back to the Mac.
    func left(_ id: UUID, from device: UUID) {
        sent[id] = nil
        channels(for: device).forEach { $0.send(LinkUpdate.leave(imp: id)) }
    }

    /// The phone throws, the Mac can't take it (it's busy flying somewhere): it bounces back.
    func refuse(_ id: UUID, on device: UUID, reason: String) {
        channels(for: device).forEach { $0.send(LinkUpdate.refused(imp: id, reason: reason)) }
    }

    /// An animation played on an Imp that's on a phone: the phone plays it.
    func animate(_ id: UUID, beats: [AnimationBeat]) {
        guard !beats.isEmpty, let device = app.profile(id)?.awayOn else { return }
        channels(for: device).forEach { $0.send(LinkUpdate.animate(imp: id, beats: beats)) }
    }

    private func channels(for device: UUID) -> [LinkChannel] {
        peers.values.filter { $0.device == device }.map(\.channel)
    }

    // MARK: Watching Imps on phones

    /// Follows an Imp on a phone: its looks, mood, work in progress and chat. Changes are
    /// gathered for a moment (a streaming answer changes many times a second) and only what
    /// changed is sent.
    func watch(_ id: UUID) {
        guard let device = app.profile(id)?.awayOn, app.imp(id) != nil else { return }
        let now = withObservationTracking { snapshot(id) } onChange: { [weak self] in
            Task { @MainActor in self?.changed(id) }
        }
        guard let now, !channels(for: device).isEmpty else { return }
        let before = sent[id]
        var updates: [LinkUpdate] = []
        if before?.look != now.look { updates.append(.look(imp: now.look)) }
        if before?.mood != now.mood { updates.append(.mood(imp: id, mood: now.mood)) }
        if before?.chat != now.chat { updates.append(.chat(imp: id, turns: now.chat)) }
        if before == nil || before?.work != now.work { updates.append(.work(imp: id, work: now.work)) }
        sent[id] = now
        for channel in channels(for: device) { updates.forEach(channel.send) }
    }

    private func changed(_ id: UUID) {
        guard flushing.insert(id).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.flushing.remove(id)
            self?.watch(id)
        }
    }

    private func snapshot(_ id: UUID) -> Snapshot? {
        guard let imp = app.imp(id), let profile = app.profile(id) else { return nil }
        let work = imp.work.map { w in
            LinkWork(request: w.ask.request, status: w.steps.last { $0.state == .running }?.title, partial: w.text)
        }
        return Snapshot(look: LinkImp(profile), mood: (imp.activity?.mood ?? .idle).rawValue, work: work,
                        chat: imp.history.current.turns.suffix(Self.chatPage).map(LinkTurn.init))
    }

    /// Keeps every phone told which Imps are out on the Mac (to send messages to).
    private func watchOthers() {
        let now = withObservationTracking { others() } onChange: { [weak self] in
            Task { @MainActor in self?.watchOthers() }
        }
        guard now != lastOthers else { return }
        lastOthers = now
        peers.values.filter { $0.device != nil }.forEach { $0.channel.send(LinkUpdate.others(now)) }
    }

    private func others() -> [LinkImp] {
        app.prefs.imps.filter { $0.isActive && $0.awayOn == nil }.map(LinkImp.init)
    }

    // MARK: About this Mac

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// Names and addresses a phone can try when Bonjour can't find the Mac: its local host name and
    /// every IPv4 address it has (Wi-Fi, Ethernet, a VPN like Tailscale).
    static func hosts() -> [String] {
        var hosts: [String] = []
        if let local = Host.current().names.first(where: { $0.hasSuffix(".local") }) { hosts.append(local) }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return hosts }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if !address.hasPrefix("169.254."), !hosts.contains(address) { hosts.append(address) }
        }
        return Array(hosts.prefix(6))
    }
}
