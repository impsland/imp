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
///
/// A phone has Imps of its own too (pocket Imps), which think there. They talk with the Imps here
/// in both directions (`imp_message`), and one tossed off the phone moves in for good (`adoptPocket`).
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
        /// Pocket Imps taken in, so a phone that asks again isn't refused (optional: older files lack it).
        var adopted: [Adopted]?
    }

    private struct Adopted: Codable, Equatable {
        var imp: UUID
        var phone: UUID
    }

    /// Phones that have connected since pairing was set up.
    private(set) var phones: [Phone] = []
    /// Phones connected right now: id → name.
    private(set) var connected: [UUID: String] = [:]
    /// An iPhone is set up (pairing was opened at least once): the desktop's edges throw.
    private(set) var isSetUp = false
    /// Why the Mac can't listen, if it can't.
    private(set) var problem: String?
    /// The pocket Imps of the phones connected right now, as each phone announced them.
    private var pocket: [UUID: [LinkImp]] = [:]

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var saved: Saved?
    @ObservationIgnored private var listener: NWListener?
    /// The waiting connection at the Hop (when a server is set), and what it was started for.
    @ObservationIgnored private var hopHost: HopHost?
    @ObservationIgnored private var hopFor: (server: ImpServer, port: UInt16)?
    @ObservationIgnored private var watchingServer = false
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    /// What each phone was last told about each of its Imps (only changes are sent).
    @ObservationIgnored private var sent: [UUID: Snapshot] = [:]
    @ObservationIgnored private var flushing: Set<UUID> = []
    @ObservationIgnored private var lastOthers: [LinkImp] = []
    /// Questions Imps here asked pocket Imps, waiting for the answer.
    @ObservationIgnored private var asks: [UUID: Ask] = [:]
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

    private struct Ask {
        let phone: UUID
        let reply: CheckedContinuation<String, Error>
    }

    /// What a phone knows about one of its Imps.
    private struct Snapshot: Equatable {
        var look: LinkImp
        var mood: String
        var work: LinkWork?
        var chat: [LinkTurn]
        var speech: LinkSpeech?
    }

    /// Turns of the current chat a phone is sent (it shows the latest; the Mac keeps them all).
    static let chatPage = 40
    /// Longest message a phone may send.
    static let maxText = 20_000
    /// Seconds a pocket Imp has to answer an Imp here.
    static let askTimeout: TimeInterval = 120
    /// Most pocket Imps a phone may announce.
    static let maxPocket = 50

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
        startWatchingServer()
    }

    /// The pairing link (and QR code) for a new phone. Sets the link up the first time.
    func pairing() -> LinkPairing {
        if saved == nil {
            saved = Saved(mac: UUID(), secret: LinkPairing.newSecret(), phones: [])
            save()
            isSetUp = true
            listen()
            watchOthers()
            startWatchingServer()
        }
        let s = saved!
        return LinkPairing(mac: s.mac, name: Self.macName, secret: s.secret, hosts: Self.hosts(),
                           port: listener?.port?.rawValue ?? LinkProtocol.port, hop: ImpServer(app.prefs.server)?.hop)
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
        pocket = [:]
        failAsks(of: nil)
        phones = []
        sent = [:]
        listener?.cancel()
        listener = nil
        saved = nil
        updateHop()
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
        // A model that doesn't persist (design renders, tests) never touches the real pairing.
        guard app.persists, var s = saved else { return }
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
                Task { @MainActor in
                    self?.problem = nil
                    self?.updateHop()
                }
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
            guard case .closed(_, let reason) = state else { return }
            Task { @MainActor in self?.dropped(id, reason: reason) }
        }
        channel.start()
    }

    private func dropped(_ id: UUID, reason: String?) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        if let device = peer.device, !peers.values.contains(where: { $0.device == device }) {
            connected[device] = nil
            pocket[device] = nil
            failAsks(of: device)
            log.info("iPhone “\(peer.name, privacy: .public)” left: \(reason ?? "closed", privacy: .public)")
        }
    }

    // MARK: Reaching this Mac from anywhere

    /// Follows the server setting: phones are told where to find the Hop, and the waiting connection
    /// there follows it.
    private func startWatchingServer() {
        if !watchingServer { watchServer() }
    }

    private func watchServer() {
        guard saved != nil else { return watchingServer = false }
        watchingServer = true
        let server = withObservationTracking { ImpServer(app.prefs.server) } onChange: { [weak self] in
            Task { @MainActor in self?.watchServer() }
        }
        updateHop()
        let route = LinkUpdate.route(hop: server?.hop)
        peers.values.filter { $0.device != nil }.forEach { $0.channel.send(route) }
    }

    /// Keeps one connection waiting at the Hop while a server is set and a phone is paired. Over it,
    /// phones come in as plain TCP to the Link listener on this Mac, where TLS ends as it always does.
    private func updateHop() {
        let want = (saved != nil ? ImpServer(app.prefs.server) : nil)
            .flatMap { server in listener?.port.map { (server, $0.rawValue) } }
        if let want, let have = hopFor, want.0 == have.server, want.1 == have.port { return }
        hopHost?.stop()
        hopHost = nil
        hopFor = nil
        guard let (server, port) = want, let s = saved, let address = HopAddress(server.hop) else { return }
        let host = HopHost(address: address, room: Hop.Room(secret: s.secret), loopbackPort: port)
        host.onRejected = { [weak self] in
            Task { @MainActor in
                self?.problem = String(localized: "The server turned this Mac away, so your iPhone can't reach it from afar.")
            }
        }
        host.start()
        hopHost = host
        hopFor = (server, port)
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
        case .file(let transfer, let imp, let ref):
            guard let model = own(imp) else {
                return peer.channel.send(LinkUpdate.fileFailed(id: transfer, reason: String(localized: "That Imp isn't on this phone.")))
            }
            sendFile(ref, of: model, transfer: transfer, over: peer.channel)
        case .troupe(let imps):
            pocket[device] = Array(imps.compactMap(Self.announced).prefix(Self.maxPocket))
        case .adopt(let imp, let kit, let secrets, let exit, let height, let speed):
            adopt(imp, kit: kit, secrets: secrets, entry: .after(exit: exit, height: height, speed: speed), from: device)
        case .message(let id, let from, let to, let text):
            relay(id, from: from, to: to, text: text, device: device)
        case .talks(let imp):
            // Only for an Imp that's on this phone or one of its pocket Imps; nothing else is shared.
            guard app.profile(imp)?.awayOn == device || pocket[device]?.contains(where: { $0.id == imp }) == true else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mine = await app.talkLines().filter { $0.asker.id == imp || $0.answerer.id == imp }
                let update = LinkUpdate.talks(imp: imp, lines: TalkLog.forLink(mine))
                for peer in peers.values where peer.device == device { peer.channel.send(update) }
            }
        case .answered(let id, let text, let failed):
            guard asks[id]?.phone == device else { return }
            let words = String(text.prefix(Self.maxText))
            settle(id, failed ? .failure(ToolArgumentError(words)) : .success(words))
        }
    }

    /// A pocket Imp as announced, kept to what's sane.
    private static func announced(_ imp: LinkImp) -> LinkImp? {
        let name = imp.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var imp = imp
        imp.name = String(name.prefix(PocketImp.maxName))
        imp.hue = imp.hue.isFinite ? min(max(imp.hue, 0), 1) : 0
        return imp
    }

    /// Sends a file one of the Imp's replies shows or links to, in parts, at the network's pace.
    /// Only files a reply mentions (see `LinkFiles`), only regular files, never too big.
    private func sendFile(_ ref: String, of imp: ImpModel, transfer: UUID, over channel: LinkChannel) {
        var texts = imp.history.current.turns.map(\.reply)
        if let b = imp.bubble { texts.append(b.text) }
        if let w = imp.work { texts.append(w.text) }
        func fail(_ reason: String) { channel.send(LinkUpdate.fileFailed(id: transfer, reason: reason)) }
        guard LinkFiles.isMentioned(ref, in: texts), let url = LinkFiles.resolve(ref, base: Workspace.directory(for: imp.id)) else {
            return fail(String(localized: "That file isn't in this chat."))
        }
        let log = log
        Task.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                return channel.send(LinkUpdate.fileFailed(id: transfer, reason: String(localized: "The file isn't on the Mac any more.")))
            }
            guard size <= LinkFilePart.maxSize else {
                return channel.send(LinkUpdate.fileFailed(id: transfer, reason: String(localized: "The file is too big to send to the phone.")))
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return channel.send(LinkUpdate.fileFailed(id: transfer, reason: String(localized: "Imp can't read that file.")))
            }
            defer { try? handle.close() }
            var offset = 0
            repeat {
                guard let data = try? handle.read(upToCount: LinkFilePart.chunk) else {
                    return channel.send(LinkUpdate.fileFailed(id: transfer, reason: String(localized: "Imp can't read that file.")))
                }
                let part = LinkFilePart(name: url.lastPathComponent, size: size, offset: offset, data: data)
                guard await channel.sendAndWait(LinkUpdate.file(id: transfer, part: part)) else { return }
                offset += data.count
                if data.isEmpty { break }
            } while offset < size
            log.info("sent \(url.lastPathComponent, privacy: .public) (\(size) bytes) to the phone")
        }
    }

    private func hello(_ peer: Peer, device: UUID, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        peer.device = device
        peer.name = name.isEmpty ? String(localized: "iPhone") : name
        peer.since = Date()
        // A phone that reconnects can beat the death of its old connection: that one goes now, so
        // nothing is sent twice.
        for (id, old) in peers where id != peer.channel.id && old.device == device {
            peers[id] = nil
            old.channel.onState = nil
            old.channel.onFrame = nil
            old.channel.close()
        }
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
        peer.channel.send(LinkUpdate.route(hop: ImpServer(app.prefs.server)?.hop))
        // Everything about them, fresh.
        for p in mine {
            sent[p.id] = nil
            watch(p.id)
        }
    }

    // MARK: Pocket Imps

    /// The Imps hatched on connected phones, by name, with the phone each is on.
    var pocketImps: [(imp: LinkImp, phone: UUID)] {
        pocket.flatMap { phone, imps in imps.map { ($0, phone) } }.sorted { $0.imp.name < $1.imp.name }
    }

    /// An Imp here asks a pocket Imp something and waits for its answer (`askTimeout`). Throws why it
    /// can't be answered: its phone went away, it took too long, or the Imp says it couldn't.
    func ask(_ imp: LinkImp, on phone: UUID, from sender: ImpProfile, text: String) async throws -> String {
        let channels = channels(for: phone)
        guard pocket[phone]?.contains(where: { $0.id == imp.id }) == true, !channels.isEmpty else {
            throw ToolArgumentError(String(localized: "\(imp.name) isn't reachable right now."))
        }
        let id = UUID()
        let words = String(text.prefix(Self.maxText))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                asks[id] = Ask(phone: phone, reply: reply)
                channels.forEach { $0.send(LinkUpdate.ask(id: id, from: LinkImp(sender), to: imp.id, text: words)) }
                if Task.isCancelled { return settle(id, .failure(CancellationError())) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.askTimeout))
                    self?.settle(id, .failure(ToolArgumentError(String(localized: "\(imp.name) didn't answer in time."))))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle(id, .failure(CancellationError())) }
        }
    }

    private func settle(_ id: UUID, _ result: Result<String, Error>) {
        asks.removeValue(forKey: id)?.reply.resume(with: result)
    }

    /// Questions to a phone that's gone (nil: every phone) fail now, not after the wait.
    private func failAsks(of phone: UUID?) {
        for (id, ask) in asks where phone == nil || ask.phone == phone {
            settle(id, .failure(ToolArgumentError(String(localized: "That iPhone went away."))))
        }
    }

    /// A pocket Imp asks an Imp here. Only the Imps the phone announced may ask, and any Imp that's
    /// out answers: on the desktop, or on a phone (it still thinks here, and its bubble shows there).
    /// Whatever goes wrong comes back as a failed answer.
    private func relay(_ id: UUID, from: UUID, to: UUID, text: String, device: UUID) {
        func reply(_ text: String, failed: Bool) {
            channels(for: device).forEach { $0.send(LinkUpdate.answer(id: id, text: String(text.prefix(Self.maxText)), failed: failed)) }
        }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let me = pocket[device]?.first(where: { $0.id == from }) else {
            return reply(String(localized: "That Imp isn't on this phone."), failed: true)
        }
        guard !words.isEmpty, let target = app.profile(to), target.isActive, let model = app.imp(to) else {
            return reply(String(localized: "That Imp isn't out on the desktop."), failed: true)
        }
        let sender = ChatTurn.Sender(id: me.id, name: me.name, hue: me.hue)
        let place = app.prefs.impTalk.place(asked: nil)
        Task {
            do { reply(try await model.answer(String(words.prefix(Self.maxText)), from: sender, in: place), failed: false) }
            catch { reply(error.localizedDescription, failed: true) }
        }
    }

    /// A pocket Imp moves in. A phone that asks again for one already taken in is told so again.
    private func adopt(_ imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry, from device: UUID) {
        let record = Adopted(imp: imp, phone: device)
        if app.profile(imp) != nil, saved?.adopted?.contains(record) != true {
            return refuse(imp, on: device, reason: PocketError.alreadyHere.localizedDescription)
        }
        if app.profile(imp) == nil {
            do { try app.adoptPocket(imp, kit: kit, secrets: secrets, entry: entry) }
            catch { return refuse(imp, on: device, reason: error.localizedDescription) }
            let taken = (saved?.adopted ?? []) + [record]
            saved?.adopted = Array(taken.suffix(500))
            save()
            log.info("a pocket Imp moved in from iPhone “\(self.name(of: device) ?? "", privacy: .public)”")
        }
        channels(for: device).forEach { $0.send(LinkUpdate.adopted(imp: imp)) }
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
        if before == nil || before?.speech != now.speech { updates.append(.speech(imp: id, speech: now.speech)) }
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
            LinkWork(request: w.ask.request, status: w.steps.last { $0.state == .running }?.title, partial: w.text,
                     from: w.received?.peer.name)
        }
        // Talks with other Imps show as its speech bubble on the phone, not in your chat there.
        let chat = imp.history.current.turns.filter { $0.sender == nil }.suffix(Self.chatPage).map(LinkTurn.init)
        return Snapshot(look: LinkImp(profile), mood: (imp.activity?.mood ?? .idle).rawValue, work: work,
                        chat: chat, speech: Self.speech(imp.bubble))
    }

    /// The bubble's talk with another Imp, if that's what it shows.
    private static func speech(_ bubble: Bubble?) -> LinkSpeech? {
        guard let b = bubble, let ex = b.exchange, [.thinking, .result, .error].contains(b.phase) else { return nil }
        let role: LinkSpeech.Role = switch ex.role {
        case .asked: .asked
        case .reply: .reply
        case .asking: .asking
        }
        return LinkSpeech(id: b.id, role: role, peer: ex.peer.name, hue: ex.peer.hue, question: ex.question,
                          text: role == .reply ? b.text : "")
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
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !address.hasPrefix("169.254."), !hosts.contains(address) { hosts.append(address) }
        }
        return Array(hosts.prefix(6))
    }
}
