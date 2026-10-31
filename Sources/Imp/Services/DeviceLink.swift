import AppKit
import ImpKit
import Observation
import os

/// The Mac's part in Imp Link 2 (see `docs/LINK.md`): one `LinkNode` that finds, links with and
/// talks to the other devices, and everything the app does with what it hears.
///
/// An Imp of this Mac is still this Mac's wherever its body is: its brain, keys, tools and chats stay
/// here. A device it was thrown to draws it and is its chat; this relays what the Imp is doing
/// (`watch`) and answers what that device asks of it. Only the device that holds an Imp may ask.
///
/// Imps of other devices think there. Ours talk with them in both directions (`imp_message`).
@MainActor @Observable
final class DeviceLink {
    /// A device this Mac is linked with, as Settings and the menus show it.
    struct Peer: Identifiable, Equatable {
        enum Reach { case direct, viaServer, away }
        var id: UUID
        var name: String
        var kind: LinkKind
        var reach: Reach
        /// The Imps of this Mac it holds right now.
        var imps: [UUID]

        var isConnected: Bool { reach != .away }
    }

    /// The linked devices.
    private(set) var peers: [Peer] = []
    /// Something that went wrong that the person may want to know.
    private(set) var problem: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var node: LinkNode?
    /// What each device was last told about each of its Imps (only changes are sent).
    @ObservationIgnored private var sent: [UUID: Snapshot] = [:]
    @ObservationIgnored private var flushing: Set<UUID> = []
    /// Questions Imps here asked Imps on other devices, waiting for the answer.
    @ObservationIgnored private var asks: [UUID: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "link")

    /// What a device knows about one of our Imps that it holds.
    private struct Snapshot: Equatable {
        var look: LinkImp
        var mood: String
        var work: LinkWork?
        var chat: [LinkTurn]
        var speech: LinkSpeech?
    }

    /// Turns of the current chat a device is sent (it shows the latest; the Mac keeps them all).
    static let chatPage = 40

    init(app: AppModel) { self.app = app }

    static var file: URL { URL.applicationSupportDirectory.appendingPathComponent("Imp/link.json") }
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    // MARK: Starting and stopping

    /// Comes up: listens, advertises, and dials the devices it is linked with. A model that doesn't
    /// persist (design renders, tests) never touches the real book or the network.
    func start() {
        guard app.persists, node == nil else { return }
        // The first iPhone link kept its secret here. Imp Link 2 starts afresh.
        try? FileManager.default.removeItem(at: Self.file.deletingLastPathComponent().appendingPathComponent("iphone.json"))
        let node: LinkNode
        do { node = try LinkNode(name: Self.deviceName, kind: .mac, storage: LinkFileStorage(url: Self.file)) }
        catch {
            log.error("couldn't open the link book: \(error.localizedDescription, privacy: .public)")
            problem = String(localized: "Imp can't read its list of linked devices.")
            return
        }
        node.onEvent = { [weak self] event in self?.handle(event) }
        self.node = node
        // The ledger is the truth about where our Imps are.
        app.reconcileAway(Dictionary(node.away.entries.map { ($0.imp, $0.holder) }, uniquingKeysWith: { $1 }))
        // The Imps visiting before the app closed are back, asleep until their homes connect.
        node.visits.visits.forEach { app.welcome(visiting($0), entry: nil) }
        refresh()
        watchServer()
        watchStage()
        Task { await node.start() }
    }

    func stop() { node?.stop() }

    // MARK: What the app asks

    /// This Mac has linked with some device (the desktop's edges throw).
    var isLinked: Bool { !peers.isEmpty }
    /// The devices an Imp can be thrown to right now.
    var connectedPeers: [Peer] { peers.filter(\.isConnected) }
    func name(of device: UUID) -> String? { peers.first { $0.id == device }?.name }
    func isConnected(_ device: UUID) -> Bool { peers.first { $0.id == device }?.isConnected == true }

    /// Where an Imp thrown off a side of the desktop goes.
    func door(of imp: UUID, side: LinkSide, height: Double) -> LinkDoors.Outcome {
        node?.door(of: imp, side: side, height: height) ?? .bounce(.nobodyConnected)
    }

    /// The bands of a side, one per device it leads to.
    func bands(of imp: UUID, side: LinkSide) -> [LinkDoors.Band] { node?.bands(of: imp, side: side) ?? [] }

    /// Throws an Imp to a device. The answer comes back to the app as `passed`.
    func pass(_ imp: LinkImp, entry: LinkEntry, to device: UUID) -> UUID? {
        node?.pass(imp, entry: entry, to: device)
    }

    /// Takes one of our Imps back from the device that holds it.
    func callHome(_ imp: UUID) {
        node?.callHome(imp)
        sent[imp] = nil
        refresh()
    }

    /// Sends a visiting Imp home from here. False if it isn't one.
    func sendHome(visitor imp: UUID) -> Bool {
        guard node?.sendHome(imp) == true else { return false }
        refresh()
        return true
    }

    // MARK: To the home of a visiting Imp

    func ask(_ imp: UUID, _ text: String) { tell(imp, .ask(imp: imp, text: String(text.prefix(LinkProtocol.maxText)))) }
    func stop(_ imp: UUID) { tell(imp, .stop(imp: imp)) }
    func newChat(_ imp: UUID) { tell(imp, .newChat(imp: imp)) }
    func felt(_ imp: UUID, _ feeling: LinkFeeling) { tell(imp, .felt(imp: imp, feeling: feeling)) }

    private func tell(_ imp: UUID, _ message: LinkMessage) {
        guard let home = node?.visits.visit(of: imp)?.home.id else { return }
        node?.send(message, to: home)
    }

    /// A visit as the desktop draws it: asleep while its home isn't connected.
    private func visiting(_ visit: Visits.Visit) -> Visiting {
        Visiting(look: visit.imp, homeID: visit.home.id, homeName: visit.home.device.name,
                 isAwake: node?.isConnected(visit.home.id) == true, side: visit.side)
    }

    /// An Imp that came home or was deleted needs nothing more said about it.
    func forget(imp: UUID) {
        sent[imp] = nil
        refresh()
    }

    /// A new code to show. The previous one stops working. Nil when the link isn't running.
    func invite() -> LinkInvite? { node?.invite() }
    func inviteHidden() { node?.inviteHidden() }

    /// Links with the device that showed `invite`.
    func join(_ invite: LinkInvite) async throws -> LinkDevice {
        guard let node else { throw LinkNode.JoinError.notRunning }
        let device = try await node.join(invite)
        refresh()
        return device
    }

    func forget(_ device: UUID) {
        guard let node else { return }
        returned(node.forget(device))
        refresh()
    }

    func forgetEveryone() {
        guard let node else { return }
        returned(node.forgetEveryone())
        refresh()
    }

    /// Imps of ours that were held by a device that is gone come home, and the visitors from it go home.
    private func returned(_ forgotten: LinkNode.Forgotten) {
        forgotten.calledHome.forEach { app.cameHome($0) }
        forgotten.sentHome.forEach { app.farewell(visitor: $0) }
    }

    // MARK: Events

    private func handle(_ event: LinkNode.Event) {
        switch event {
        case .connected(let device, _):
            problem = nil
            log.info("“\(device.name, privacy: .public)” is connected")
            refresh()
        case .disconnected:
            refresh()
        case .linked(let device):
            log.info("linked with “\(device.name, privacy: .public)”")
            refresh()
        case .forgotten(_, let result):
            log.info("a device forgot this Mac")
            returned(result)
            refresh()
        case .message(let message, let from):
            receive(message, from: from)
        case .passed(let passed):
            app.passed(passed)
            refresh()
        case .problem(let problem):
            self.problem = describe(problem)
        }
    }

    private func describe(_ problem: LinkNode.Problem) -> String? {
        func who(_ id: UUID) -> String { name(of: id) ?? String(localized: "A device") }
        switch problem {
        case .listener: return String(localized: "Imp can't listen for your other devices on this network.")
        case .storage: return String(localized: "Imp can't save its list of linked devices.")
        case .refused(let id): return String(localized: "\(who(id)) doesn't know this Mac any more. Link it again.")
        case .keyChanged(let id): return String(localized: "\(who(id)) isn't the device it was when you linked it, so Imp turned it away.")
        case .badProof: return nil
        case .hop: return String(localized: "The server turned this Mac away, so your devices can't reach it from afar.")
        case .inviteRefused(let id): return String(localized: "\(who(id)) wouldn't link: its code ran out or was replaced. Show a fresh one.")
        case .full: return String(localized: "Imp has reached its limit of linked devices.")
        }
    }

    /// Settings follows who is linked, who is connected and what each device holds.
    private func refresh() {
        guard let node else { return peers = [] }
        let now = node.links.map { link -> Peer in
            let id = link.device.id
            let reach: Peer.Reach = !node.isConnected(id) ? .away : node.isThroughHop(id) ? .viaServer : .direct
            return Peer(id: id, name: link.device.name, kind: link.device.kind, reach: reach, imps: node.away.held(by: id))
        }
        if now != peers { peers = now }
        // Visitors sleep while their homes are away, and wear the looks their homes gave them.
        for visit in node.visits.visits { app.visitor(visit.id)?.update(visiting(visit)) }
    }

    // MARK: From other devices

    private func receive(_ message: LinkMessage, from device: UUID) {
        guard let node else { return }
        /// Only an Imp that's on a screen takes orders, and only from the device that holds it.
        func own(_ imp: UUID) -> ImpModel? { node.holder(of: imp) == device ? app.imp(imp) : nil }
        switch message {
        case .pass(let transfer, let imp, let entry, let home, _):
            thrown(transfer, imp: imp, entry: entry, home: home, from: device)
        case .adopt(let transfer, let imp, let kit, let secrets, let entry):
            review(adoption: transfer, imp: imp, kit: kit, secrets: secrets, entry: entry, from: device)
        case .claim(let imp, _):
            // A new holder: it is told everything about the Imp afresh.
            guard app.profile(imp) != nil else { return }
            app.held(imp, by: device)
            sent[imp] = nil
            watch(imp)
            refresh()
        case .release(let imp, _):
            app.cameHome(imp)
            refresh()
        case .ask(let imp, let text):
            let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LinkProtocol.maxText))
            guard let model = own(imp), !words.isEmpty else { return }
            model.ask(words)
        case .stop(let imp):
            own(imp)?.cancel()
        case .newChat(let imp):
            own(imp)?.newChat()
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
                return fail(file: transfer, String(localized: "That Imp isn't on this device."), to: device)
            }
            sendFile(ref, of: model, transfer: transfer, to: device)
        case .talks(let imp):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mine = await app.talkLines().filter { $0.asker.id == imp || $0.answerer.id == imp }
                node.send(.talkLines(imp: imp, lines: TalkLog.forLink(mine)), to: device)
            }
        case .message(let id, let sender, let to, _, let text, _):
            answer(id, from: sender, to: to, text: text, back: device)
        case .answer(let id, let text, let failed):
            let words = String(text.prefix(LinkProtocol.maxText))
            settle(id, failed ? .failure(ToolArgumentError(words)) : .success(words))
        case .look:
            refresh()                                          // the node has its new looks
        case .chat(let imp, let turns): app.visitor(imp)?.heard(chat: turns)
        case .work(let imp, let work): app.visitor(imp)?.heard(work: work)
        case .mood(let imp, let mood): app.visitor(imp)?.heard(mood: mood)
        case .speech(let imp, let speech): app.visitor(imp)?.heard(speech: speech)
        case .animate(let imp, let beats): app.visitor(imp)?.acted(beats)
        case .gone(let imp):
            app.farewell(visitor: imp)
            refresh()
        default:
            // The rest of what a visiting Imp's home says (files, talks) isn't shown on the Mac yet.
            break
        }
    }

    // MARK: Imps coming and going

    /// An Imp was thrown here. Ours coming home are taken; a visitor is drawn on the desktop (the
    /// node says no when it holds as many visits as it can).
    private func thrown(_ transfer: UUID, imp: LinkImp, entry: LinkEntry, home: LinkCard?, from device: UUID) {
        guard let node else { return }
        if home != nil {
            guard node.accept(transfer), let visit = node.visits.visit(of: imp.id) else { return }
            app.welcome(visiting(visit), entry: entry)
            refresh()
        } else if app.profile(imp.id) != nil {
            if node.accept(transfer) {
                app.cameHome(imp.id, entry: entry)
                refresh()
            }
        } else {
            log.info("turned down an Imp that isn't ours and has no home to think at")
            node.decline(transfer, reason: .other)
        }
    }

    /// A phone's pocket Imp asks to move in for good: the kit review comes up, and only Add takes it.
    private func review(adoption transfer: UUID, imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry, from device: UUID) {
        guard let node else { return }
        guard let parsed = try? Kit.parse(kit, limit: LinkProtocol.maxFrame) else {
            return node.decline(transfer, reason: .other)
        }
        let origin = name(of: device) ?? String(localized: "Another device")
        let review = KitReview(kit: parsed, origin: origin, existing: app.prefs.shortcuts, services: app.prefs.ai.services, target: nil)
        let flow = KitFlow(imp: nil)
        flow.review = review
        flow.adoption = { [weak self] agreed in
            guard let self, let node = self.node else { return }
            guard agreed else { return node.decline(transfer, reason: .other) }
            do {
                try self.app.adoptPocket(imp, kit: kit, secrets: secrets, entry: entry)
                node.accept(transfer)
                self.log.info("a pocket Imp moved in from “\(origin, privacy: .public)”")
            } catch {
                node.decline(transfer, reason: .other)
                self.problem = error.localizedDescription
            }
        }
        HomeWindow.shared.showKit(app, flow)
    }

    // MARK: To the device that holds an Imp

    private func holder(of imp: UUID) -> UUID? { node?.holder(of: imp) }

    /// An animation played on an Imp that's on another device: that device plays it.
    func animate(_ id: UUID, beats: [AnimationBeat]) {
        guard !beats.isEmpty, let device = holder(of: id) else { return }
        node?.send(.animate(imp: id, beats: beats), to: device)
    }

    /// Follows an Imp on another device: its looks, mood, work in progress and chat. Changes are
    /// gathered for a moment (a streaming answer changes many times a second) and only what changed
    /// is sent.
    func watch(_ id: UUID) {
        guard let node, let device = node.holder(of: id), app.imp(id) != nil else { return }
        let now = withObservationTracking { snapshot(id) } onChange: { [weak self] in
            Task { @MainActor in self?.changed(id) }
        }
        guard let now, node.isConnected(device) else { return }
        let before = sent[id]
        var updates: [LinkMessage] = []
        if before?.look != now.look { updates.append(.look(imp: now.look)) }
        if before?.mood != now.mood { updates.append(.mood(imp: id, mood: now.mood)) }
        if before?.chat != now.chat { updates.append(.chat(imp: id, turns: now.chat)) }
        if before == nil || before?.work != now.work { updates.append(.work(imp: id, work: now.work)) }
        if before == nil || before?.speech != now.speech { updates.append(.speech(imp: id, speech: now.speech)) }
        sent[id] = now
        updates.forEach { node.send($0, to: device) }
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
        // Talks with other Imps show as its speech bubble there, not in your chat.
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

    // MARK: Files

    private func fail(file transfer: UUID, _ reason: String, to device: UUID) {
        node?.send(.fileFailed(id: transfer, reason: reason), to: device)
    }

    /// Sends a file one of the Imp's replies shows or links to, in parts, at the network's pace.
    /// Only files a reply mentions (see `LinkFiles`), only regular files, never too big.
    private func sendFile(_ ref: String, of imp: ImpModel, transfer: UUID, to device: UUID) {
        guard let node else { return }
        var texts = imp.history.current.turns.map(\.reply)
        if let b = imp.bubble { texts.append(b.text) }
        if let w = imp.work { texts.append(w.text) }
        let folder = Workspace.directory(for: imp.id)
        guard LinkFiles.mayServe(ref, base: folder, in: texts, trusted: node.isTrusted(device)), let url = LinkFiles.resolve(ref, base: folder) else {
            return fail(file: transfer, String(localized: "That file isn't in this chat."), to: device)
        }
        let log = log
        Task.detached(priority: .userInitiated) {
            func fail(_ reason: String) async { await node.send(.fileFailed(id: transfer, reason: reason), to: device) }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                return await fail(String(localized: "The file isn't on the Mac any more."))
            }
            guard size <= LinkFilePart.maxSize else {
                return await fail(String(localized: "The file is too big to send."))
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return await fail(String(localized: "Imp can't read that file."))
            }
            defer { try? handle.close() }
            var offset = 0
            repeat {
                guard let data = try? handle.read(upToCount: LinkFilePart.chunk) else {
                    return await fail(String(localized: "Imp can't read that file."))
                }
                let part = LinkFilePart(name: url.lastPathComponent, size: size, offset: offset, data: data)
                guard await node.sendAndWait(.filePart(id: transfer, part: part), to: device) else { return }
                offset += data.count
                if data.isEmpty { break }
            } while offset < size
            log.info("sent \(url.lastPathComponent, privacy: .public) (\(size) bytes)")
        }
    }

    // MARK: Imps talking

    /// The Imps on other devices one of ours can message: those on the screen its body is on (the
    /// Imps of this Mac are reached directly, wherever they are).
    func targets(of imp: UUID) -> [LinkStaged] {
        guard let node else { return [] }
        let me = node.device.id
        let mine = app.prefs.imps.filter(\.isActive).map { LinkStaged(imp: LinkImp($0), home: me) }
        let stage = node.holder(of: imp).map(node.stage(of:)) ?? visitorsStaged
        return LinkTalks.targets(of: imp, mine: mine, stage: stage).filter { $0.home != me }
    }

    /// An Imp here asks an Imp on another device something and waits for its answer. Throws why it
    /// can't be answered: its device went away, it took too long, or the Imp says it couldn't.
    func talk(from sender: ImpProfile, to target: LinkStaged, text: String) async throws -> String {
        let words = String(text.prefix(LinkProtocol.maxText))
        let unreachable = ToolArgumentError(String(localized: "\(target.imp.name) isn't reachable right now."))
        guard let node else { throw unreachable }
        let id = UUID()
        let me = LinkImp(sender)
        switch node.talk(id: id, from: me, to: target.id, toHome: target.home, text: words, holder: node.holder(of: sender.id) ?? node.device.id) {
        case .unreachable:
            throw unreachable
        case .here:
            return try await reply(from: me, to: target.id, text: words)
        case .via:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    asks[id] = continuation
                    if Task.isCancelled { settle(id, .failure(CancellationError())) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.settle(id, .failure(CancellationError())) }
            }
        }
    }

    private func settle(_ id: UUID, _ result: Result<String, Error>) {
        asks.removeValue(forKey: id)?.resume(with: result)
    }

    /// An Imp of this Mac answers another Imp.
    private func reply(from sender: LinkImp, to target: UUID, text: String) async throws -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, app.profile(target)?.isActive == true, let model = app.imp(target) else {
            throw ToolArgumentError(String(localized: "That Imp isn't out."))
        }
        let from = ChatTurn.Sender(id: sender.id, name: sender.name, hue: sender.hue)
        let place = app.prefs.impTalk.place(asked: nil)
        return try await model.answer(String(words.prefix(LinkProtocol.maxText)), from: from, in: place)
    }

    /// An Imp on another device asks one of ours. Whatever goes wrong comes back as a failed answer.
    private func answer(_ id: UUID, from sender: LinkImp, to target: UUID, text: String, back device: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let said = try await reply(from: sender, to: target, text: text)
                node?.send(.answer(id: id, text: String(said.prefix(LinkProtocol.maxText)), failed: false), to: device)
            } catch {
                node?.send(.answer(id: id, text: String(error.localizedDescription.prefix(LinkProtocol.maxText)), failed: true), to: device)
            }
        }
    }

    // MARK: Following the app

    /// The node waits at the Hop of the server in Settings, and tells the other devices.
    private func watchServer() {
        let server = withObservationTracking { ImpServer(app.prefs.server) } onChange: { [weak self] in
            Task { @MainActor in self?.watchServer() }
        }
        node?.setServer(server.flatMap { HopAddress($0.hop) })
    }

    /// The Imps visiting this desktop, as the other devices are told.
    private var visitorsStaged: [LinkStaged] {
        app.visitors.compactMap { model in model.visit.map { LinkStaged(imp: $0.look, home: $0.homeID) } }
    }

    /// The other devices are told which Imps are on this desktop, visitors too.
    private func watchStage() {
        let staged = withObservationTracking {
            app.prefs.imps.filter { $0.isActive && $0.awayOn == nil }.map { LinkStaged(imp: LinkImp($0), home: node?.device.id ?? UUID()) }
                + visitorsStaged
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchStage() }
        }
        node?.setStage(staged)
    }

    // MARK: Saying why

    /// Why an Imp thrown at an edge bounced.
    static func hint(_ bounce: LinkDoors.Bounce) -> String {
        switch bounce {
        case .nobodyConnected: String(localized: "None of your other devices is around. Open Imp on one, then throw me again.")
        case .wayBackIsClosed: String(localized: "The device I came from isn't around, so I can't go back that way.")
        case .nowhereElse: String(localized: "There's nowhere else to go that way.")
        }
    }

    /// Why a device sent a thrown Imp back.
    static func hint(_ reason: LinkDecline, device: String) -> String {
        switch reason {
        case .full: String(localized: "\(device) has no room for me.")
        case .playing: String(localized: "\(device) is in the middle of a game.")
        case .notLinked: String(localized: "\(device) doesn't know this Mac any more. Link it again in Settings.")
        case .timeout: String(localized: "\(device) didn't answer in time.")
        case .other: String(localized: "\(device) didn't take me.")
        }
    }

    /// Why a code couldn't be used.
    static func message(_ error: Error) -> String {
        guard let join = error as? LinkNode.JoinError else { return error.localizedDescription }
        return switch join {
        case .notRunning: String(localized: "Linking isn't running on this Mac.")
        case .itsOwnCode: String(localized: "That's this Mac's own code. Use the one on the other device.")
        case .keyChanged: String(localized: "That device isn't the one you linked before. Forget it first, then link it again.")
        case .full: String(localized: "This Mac can't link with any more devices.")
        case .unreachable: String(localized: "Imp couldn't reach that device. Is it open, on the same network or the same server?")
        case .refused: String(localized: "That device wouldn't link. Its code may have run out: show a fresh one.")
        case .timedOut: String(localized: "That device didn't answer in time.")
        }
    }
}
