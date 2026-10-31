import Foundation
import ImpKit
import Network
import Observation
import os
import UIKit

/// What the stage has to act out: things that happen at a moment, not states to show.
enum StageEvent {
    /// The Mac's list of Imps on this phone (on connect, or from the cache at launch).
    case roster([LinkImp])
    case arrived(LinkImp, LinkEntry)
    case left(UUID)
    case refused(UUID, String)
    case animate(UUID, [AnimationBeat])
}

/// What the Mac tells the Imps hatched on this phone.
enum PocketEvent {
    case adopted(UUID)
    case answer(id: UUID, text: String, failed: Bool)
    case ask(id: UUID, from: LinkImp, to: UUID, text: String)
    case linkLost
}

/// The phone's side of Imp Link: finds the paired Mac, keeps one connection to it, and holds what
/// the Mac says (which Imps are here, their chats, what they're doing). The Mac keeps every
/// Imp's brain; this is only the body and the chat.
@MainActor @Observable
final class LinkClient {
    enum Status: Equatable {
        case unpaired
        case searching
        case connecting
        case connected(String)
        /// The Mac answers but doesn't know this iPhone any more: it has to be paired again.
        case unknown
    }

    /// Where to try next.
    private enum Route {
        case direct(NWEndpoint)
        case hop
    }

    /// How many times in a row the Mac may refuse our key before we say so.
    private static let rejectionsBeforeSaying = 3

    private(set) var status: Status = .unpaired
    /// The link is running through the Hop (the internet), not over the local network.
    private(set) var viaHop = false
    private(set) var pairing: LinkPairing?
    private(set) var imps: [LinkImp] = []
    private(set) var others: [LinkImp] = []
    private(set) var chats: [UUID: [LinkTurn]] = [:]
    private(set) var work: [UUID: LinkWork] = [:]
    private(set) var moods: [UUID: Mood] = [:]
    /// What each Imp is saying to another Imp (a bubble above it on the stage).
    private(set) var speeches: [UUID: LinkSpeech] = [:]
    /// What the Mac's chats say each Imp talked about with other Imps (`requestTalks`). Not kept
    /// between launches; a Mac that doesn't know `talks` never fills it.
    private(set) var talkLines: [UUID: [TalkLine]] = [:]
    /// Files from the Mac that replies show (pictures, voices, videos, documents).
    @ObservationIgnored private(set) lazy var files = LinkFileStore(client: self)
    /// A short message to show (a toss that didn't work out, a pairing that didn't read).
    var toast: String?

    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored var onPocket: ((PocketEvent) -> Void)?
    /// The Imps hatched on this phone, as the Mac is told of them.
    @ObservationIgnored private(set) var troupe: [LinkImp] = []

    var isConnected: Bool { if case .connected = status { true } else { false } }
    var macName: String? { pairing?.name }

    // MARK: Private state

    @ObservationIgnored private let log = Logger(subsystem: "app.imp.ImpPhone", category: "link")
    @ObservationIgnored private var active = false
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var found: [NWEndpoint] = []
    @ObservationIgnored private var channel: LinkChannel?
    @ObservationIgnored private var channelWasReady = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var rejections = 0
    @ObservationIgnored private var hopRefused = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var demo = false

    @ObservationIgnored private let deviceID: UUID = {
        let key = "deviceID"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    init() {
        pairing = PairingStore.load()
        status = pairing == nil ? .unpaired : .searching
        if pairing != nil, let cache = Cache.load() {
            // Show what was here last time while looking for the Mac.
            imps = cache.imps; others = cache.others; chats = cache.chats
        }
    }

    // MARK: Pairing

    /// Pairs with the Mac in a link (from the camera, a scan or the pasteboard). Replaces any earlier pairing.
    func pair(_ new: LinkPairing) {
        if pairing != nil { teardown(clearCache: true) }
        PairingStore.save(new)
        pairing = new
        status = .searching
        failures = 0
        rejections = 0
        hopRefused = false
        if active { start() }
    }

    func unpair() {
        teardown(clearCache: true)
        PairingStore.delete()
        pairing = nil
        status = .unpaired
    }

    // MARK: Lifecycle

    /// The app is in front (true) or not. The link only lives in the foreground.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard pairing != nil, !demo else { return }
        stop()
        active = true
        status = .searching
        startBrowsing()
        watchNetwork()
        // Bonjour usually answers in well under a second; if not, try the addresses in the link.
        scheduleConnect(after: 0.4)
    }

    private func stop() {
        retry?.cancel(); pinger?.cancel()
        browser?.cancel(); browser = nil
        monitor?.cancel(); monitor = nil
        pathSignature = nil
        found = []
        closeChannel()
        if pairing != nil, !demo { status = .searching }
    }

    private func teardown(clearCache: Bool) {
        stop()
        imps = []; others = []; chats = [:]; work = [:]; moods = [:]; talkLines = [:]
        for (id, speech) in speeches { drop(speech, for: id) }
        if clearCache { Cache.delete() }
        onEvent?(.roster([]))
    }

    private func closeChannel() {
        channel?.onState = nil
        channel?.onFrame = nil
        channel?.close()
        channel = nil
        channelWasReady = false
        viaHop = false
        linkDropped()
    }

    /// The link is gone: files in flight fail, pocket Imps stop waiting for the Mac, and a Mac Imp's
    /// talk that can't go on (a question waiting for its answer) leaves the stage. A reply stays
    /// up to be read, then goes the way it would have.
    private func linkDropped() {
        files.linkLost()
        onPocket?(.linkLost)
        for (id, speech) in speeches {
            if speech.role == .reply { heard(nil, from: id) } else { drop(speech, for: id) }
        }
    }

    // MARK: Finding the Mac

    private func startBrowsing() {
        guard let pairing else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: .tcp)
        let mac = pairing.mac.uuidString
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // The Mac names itself in its TXT record. Services without one are tried too.
            let endpoints = results.compactMap { result -> NWEndpoint? in
                if case .bonjour(let txt) = result.metadata, let id = txt["mac"] { return id.caseInsensitiveCompare(mac) == .orderedSame ? result.endpoint : nil }
                return result.endpoint
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.found = endpoints } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Bonjour services first, then the addresses in the pairing, the Hop last.
    private var candidates: [Route] {
        guard let pairing else { return [] }
        var routes = found.map(Route.direct)
        if let port = NWEndpoint.Port(rawValue: pairing.port) {
            routes += pairing.hosts.map { .direct(.hostPort(host: NWEndpoint.Host($0), port: port)) }
        }
        if !hopRefused, pairing.hop.flatMap(HopAddress.init) != nil { routes.append(.hop) }
        return routes
    }

    /// When the network changes under a phone that isn't connected (Wi-Fi came back, it left the
    /// train's hotspot), try again right away instead of waiting out the back-off.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status) " + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pathChanged(signature, satisfied: satisfied) } }
        }
        monitor.start(queue: DispatchQueue(label: "app.imp.ImpPhone.path"))
        self.monitor = monitor
    }

    private func pathChanged(_ signature: String, satisfied: Bool) {
        let first = pathSignature == nil
        let changed = pathSignature != signature
        pathSignature = signature
        guard active, !first, changed, satisfied, !isConnected else { return }
        failures = 0
        if !channelWasReady { closeChannel() }
        scheduleConnect(after: 0.2)
    }

    private func scheduleConnect(after delay: TimeInterval) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func connect() {
        guard active, let pairing, channel == nil else { return }
        let list = candidates
        guard !list.isEmpty else {
            status = .searching
            return scheduleConnect(after: backoff())
        }
        let route = list[attempt % list.count]
        let made: LinkChannel? = switch route {
        case .direct(let endpoint): LinkChannel(to: endpoint, psk: pairing.psk)
        case .hop: LinkChannel(hopOf: pairing)
        }
        guard let channel = made else {
            attempt += 1
            return scheduleConnect(after: 0.3)
        }
        if status != .unknown { status = .connecting }
        let id = channel.id
        channel.onState = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.channelChanged(id, state) } }
        }
        channel.onFrame = { [weak self] data in
            guard let update = LinkFrame.decode(LinkUpdate.self, data) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(update) } }
        }
        self.channel = channel
        channelWasReady = false
        channel.start()
    }

    private func channelChanged(_ id: UUID, _ state: LinkChannel.State) {
        guard channel?.id == id else { return }
        switch state {
        case .ready:
            channelWasReady = true
            rejections = 0
            viaHop = channel?.isThroughHop ?? false
            channel?.send(LinkRequest.hello(device: deviceID, name: UIDevice.current.name, version: LinkProtocol.version))
            startPinging()
        case .closed(let why, let reason):
            log.info("link closed: \(reason ?? "-", privacy: .public)")
            let wasReady = channelWasReady
            channel = nil
            viaHop = false
            linkDropped()
            channelWasReady = false
            pinger?.cancel()
            guard active else { return }
            status = .searching
            if wasReady {
                failures = 0
                scheduleConnect(after: 1)
                return
            }
            attempt += 1
            failures += 1
            switch why {
            case .rejected: rejections += 1
            case .hopRefused: hopRefused = true
            case .ended, .unreachable: break
            }
            if rejections >= Self.rejectionsBeforeSaying {
                if rejections == Self.rejectionsBeforeSaying {
                    toast = String(localized: "This Mac doesn't know this iPhone any more. Pair again.")
                }
                status = .unknown
                // Keep trying, slowly: the Mac may only have been reset for a moment.
                scheduleConnect(after: 30)
            } else {
                // Another candidate to try soon, a full round without luck backs off.
                scheduleConnect(after: attempt % max(1, candidates.count) == 0 ? backoff() : 0.3)
            }
        }
    }

    /// 1s, 2s, 4s… up to 15s.
    private func backoff() -> TimeInterval { min(15, pow(2, Double(min(failures, 4)))) }

    private func startPinging() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinkProtocol.pingInterval))
                guard !Task.isCancelled else { return }
                self?.channel?.send(LinkRequest.ping)
            }
        }
    }

    // MARK: Hearing the Mac

    func handle(_ update: LinkUpdate) {
        switch update {
        case .welcome(let mac, _, let imps, let others):
            status = .connected(mac)
            failures = 0
            rejections = 0
            // Keep a name the user can recognise even if the Mac was renamed.
            if var p = pairing, p.name != mac, !mac.isEmpty { p.name = mac; pairing = p; PairingStore.save(p) }
            self.imps = imps
            self.others = others
            work = work.filter { id, _ in imps.contains { $0.id == id } }
            // A pocket Imp the Mac already has finished moving home, even if the link dropped
            // before the Mac could say so.
            for id in Set(imps.map(\.id) + others.map(\.id)) where troupe.contains(where: { $0.id == id }) {
                onPocket?(.adopted(id))
            }
            send(.troupe(troupe))
            onEvent?(.roster(imps))
        case .arrive(let imp, let entry):
            if let i = imps.firstIndex(where: { $0.id == imp.id }) { imps[i] = imp } else { imps.append(imp) }
            others.removeAll { $0.id == imp.id }
            onEvent?(.arrived(imp, entry))
        case .leave(let id):
            guard let i = imps.firstIndex(where: { $0.id == id }) else { break }
            let imp = imps.remove(at: i)
            work[id] = nil; moods[id] = nil
            if let speech = speeches[id] { drop(speech, for: id) }
            if !others.contains(where: { $0.id == id }) { others.append(imp) }
            onEvent?(.left(id))
        case .look(let imp):
            if let i = imps.firstIndex(where: { $0.id == imp.id }) { imps[i] = imp }
            if let i = others.firstIndex(where: { $0.id == imp.id }) { others[i] = imp }
        case .others(let list):
            others = list.filter { o in !imps.contains { $0.id == o.id } }
        case .chat(let id, let turns):
            chats[id] = turns
        case .work(let id, let w):
            work[id] = w
        case .mood(let id, let name):
            moods[id] = Mood(link: name)
        case .animate(let id, let beats):
            onEvent?(.animate(id, beats))
        case .refused(let id, let reason):
            onEvent?(.refused(id, reason))
        case .speech(let id, let speech):
            heard(speech, from: id)
        case .file(let transfer, let part):
            files.received(part, for: transfer)
            return                                   // nothing to save
        case .fileFailed(let transfer, let reason):
            files.failed(transfer, reason: reason)
            return
        case .talks(let id, let lines):
            talkLines[id] = lines
            return                                   // nothing to save
        case .pong:
            break
        case .adopted(let id):
            onPocket?(.adopted(id))
            return
        case .answer(let id, let text, let failed):
            onPocket?(.answer(id: id, text: text, failed: failed))
            return
        case .ask(let id, let from, let to, let text):
            onPocket?(.ask(id: id, from: from, to: to, text: text))
            return
        case .route(let hop):
            let hop = hop.flatMap(HopAddress.init)?.text
            if var p = pairing, p.hop != hop {
                p.hop = hop
                pairing = p
                PairingStore.save(p)
                hopRefused = false
            }
            return                                   // nothing to save
        }
        scheduleSave()
    }

    // MARK: Telling the Mac

    func ask(_ imp: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isConnected else { return }
        send(.ask(imp: imp, text: text))
    }

    func stop(_ imp: UUID) { send(.stop(imp: imp)) }

    /// Asks the Mac what the Imp has said with other Imps; the answer lands in `talkLines`.
    func requestTalks(_ imp: UUID) { send(.talks(imp: imp)) }

    /// Hides a speech bubble (tapped away).
    func dismissSpeech(_ imp: UUID) {
        if let speech = speeches[imp] { drop(speech, for: imp) }
    }

    @ObservationIgnored private var speechClear: [UUID: Task<Void, Never>] = [:]

    /// Takes a bubble off the stage for good, and its voices with it.
    private func drop(_ speech: LinkSpeech, for id: UUID) {
        speechClear[id]?.cancel()
        speechClear[id] = nil
        speeches[id] = nil
        StageVoice.shared.drop(owner: speech.id.uuidString)
    }

    /// The Mac's bubble came or went. One that goes stays a little longer here, long enough to read
    /// (the Mac hides its bubbles on its own clock, and you may only just have looked), and while
    /// its voice is still playing or waiting its turn.
    private func heard(_ speech: LinkSpeech?, from id: UUID) {
        speechClear[id]?.cancel()
        speechClear[id] = nil
        if let speech {
            if let old = speeches[id], old.id != speech.id { StageVoice.shared.drop(owner: old.id.uuidString) }
            speeches[id] = speech
            StageVoice.shared.expect(speech) { _ in true }
            return
        }
        guard let shown = speeches[id] else { return }
        speechClear[id] = Task { [weak self] in
            try? await StageVoice.shared.linger(over: shown)
            guard !Task.isCancelled, let self, speeches[id]?.id == shown.id else { return }
            drop(shown, for: id)
        }
    }

    /// Asks the Mac for a file (see `LinkFileStore`).
    func requestFile(_ transfer: UUID, imp: UUID, ref: String) -> Bool {
        guard isConnected, let channel else { return false }
        channel.send(LinkRequest.file(id: transfer, imp: imp, ref: ref))
        return true
    }
    func newChat(_ imp: UUID) {
        guard isConnected else { return }
        chats[imp] = []
        send(.newChat(imp: imp))
    }
    func felt(_ imp: UUID, _ feeling: LinkFeeling) { send(.felt(imp: imp, feeling: feeling)) }

    func toss(_ imp: UUID, exit: LinkSide, height: Double, speed: Double) {
        send(.toss(imp: imp, exit: exit, height: height, speed: speed))
        #if DEBUG
        if demo { demoToss(imp, exit: exit, height: height, speed: speed) }
        #endif
    }

    /// Tells the Mac which Imps live on this phone (on connect, and whenever they change).
    func setTroupe(_ looks: [LinkImp]) {
        guard looks != troupe else { return }
        troupe = looks
        send(.troupe(looks))
    }

    /// Sends a request if the Mac is there to hear it.
    @discardableResult
    func send(_ request: LinkRequest) -> Bool {
        guard isConnected, let channel else { return false }
        channel.send(request)
        return true
    }

    // MARK: Keeping a copy

    private struct Cache: Codable {
        var imps: [LinkImp]
        var others: [LinkImp]
        var chats: [UUID: [LinkTurn]]

        static var url: URL {
            URL.applicationSupportDirectory.appending(path: "link-cache.json")
        }

        static func load() -> Cache? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Cache.self, from: data)
        }

        func save() {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
        }

        static func delete() { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes the cache a moment after the last change, so a burst of chat updates is one write.
    private func scheduleSave() {
        guard !demo else { return }
        saver?.cancel()
        saver = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            Cache(imps: imps, others: others, chats: chats).save()
        }
    }

    // MARK: Demo (debug builds only)

    #if DEBUG
    /// Fills the client with a couple of Imps and a chat, with no network (`-demo`).
    func loadDemo() {
        demo = true
        pairing = LinkPairing(mac: UUID(), name: "Art's MacBook", secret: LinkPairing.newSecret())
        status = .connected("Art's MacBook")
        let bob = LinkImp(id: UUID(), name: "Bob", hue: 0.0, scale: 1, traits: .plain)
        let pip = LinkImp(id: UUID(), name: "Pip", hue: 0.57, scale: 0.85, traits: .plain)
        let moss = LinkImp(id: UUID(), name: "Moss", hue: 0.25, scale: 1.2, traits: .plain)
        imps = [bob, pip]
        others = [moss]
        let now = Date()
        chats[bob.id] = [
            LinkTurn(id: UUID(), date: now.addingTimeInterval(-300), request: "What's the weather like in Lisbon this weekend?",
                     reply: "Sunny, around **24°C** on Saturday, with a light breeze. Sunday clouds over in the evening.", failed: false, steps: ["Searched the web"]),
            LinkTurn(id: UUID(), date: now.addingTimeInterval(-200), request: "Can you ask Moss to tidy my Downloads folder?", reply: "Done: Moss sorted 42 files into folders.", failed: false, steps: ["Ran 2 tools"]),
            LinkTurn(id: UUID(), date: now.addingTimeInterval(-100), request: "Are the backups finished?", from: "Moss",
                     reply: "I couldn't reach the disk.", failed: true),
        ]
        let me = ChatTurn.Sender(id: bob.id, name: bob.name, hue: bob.hue)
        let friend = ChatTurn.Sender(id: pip.id, name: pip.name, hue: pip.hue)
        talkLines[bob.id] = [
            TalkLine(id: UUID(), date: now.addingTimeInterval(-86_400 * 2), asker: me, answerer: friend,
                     question: "Write a two-line poem about backups.", reply: "Copies asleep on a distant shelf,\nkeeping my files safe from myself.", failed: false),
            TalkLine(id: UUID(), date: now.addingTimeInterval(-3_600), asker: friend, answerer: me,
                     question: "What's the weather like in Lisbon?", reply: "Sunny, around **24°C**.", failed: false),
            TalkLine(id: UUID(), date: now.addingTimeInterval(-600), asker: me, answerer: friend,
                     question: "Is the backup done?", reply: "I couldn't reach the disk.", failed: true),
        ]
        work[bob.id] = LinkWork(request: "Summarise today's mail", status: "Reading mail", partial: "You have three new messages: one from")
        moods[bob.id] = .working
        speeches[pip.id] = LinkSpeech(id: UUID(), role: .reply, peer: "Moss", hue: 0.25, question: "Is the backup done?",
                                      text: "Yes! All **42 files** are safe on the external disk.")
        // `-demoVoice <url>`: Pip answers out loud instead (a web address, so it plays with no Mac).
        if let i = CommandLine.arguments.firstIndex(of: "-demoVoice"), CommandLine.arguments.indices.contains(i + 1) {
            speeches[pip.id] = LinkSpeech(id: UUID(), role: .reply, peer: "Moss", hue: 0.25, question: "Is the backup done?",
                                          text: "Said it out loud:\n\n![Voice reply](\(CommandLine.arguments[i + 1])#autoplay)")
        }
    }

    var isDemo: Bool { demo }

    /// Plays the Mac's part: it takes the Imp, then tosses it back a few seconds later.
    private func demoToss(_ id: UUID, exit: LinkSide, height: Double, speed: Double) {
        guard let imp = imps.first(where: { $0.id == id }) else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            handle(.leave(imp: id))
            try? await Task.sleep(for: .seconds(2.5))
            handle(.arrive(imp: imp, entry: .after(exit: exit.opposite, height: 0.4, speed: 1_600)))
        }
    }
    #endif
}
