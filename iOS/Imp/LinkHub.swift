import Foundation
import ImpKit
import Observation
import UIKit

/// What the stage has to act out: things that happen at a moment, not states to show.
enum StageEvent {
    /// The Imps on this screen changed (a look, an Imp sent home or called home).
    case roster
    case arrived(LinkImp, LinkEntry)
    case left(UUID)
    case refused(UUID, String)
    case animate(UUID, [AnimationBeat])
}

/// What other devices ask of the Imps hatched on this iPhone, which think here wherever they are.
enum PocketEvent {
    /// Its holder asks something of an Imp that is away: it answers as if asked here.
    case ask(UUID, String)
    case stop(UUID)
    case newChat(UUID)
    case felt(UUID, LinkFeeling)
    case file(id: UUID, imp: UUID, from: UUID)
    case talks(UUID, from: UUID)
    /// A device became the holder of one of our Imps: it needs to hear how it looks and what it's doing.
    case claimed(UUID)
    /// A message between Imps: an Imp of ours is asked something by an Imp of another device.
    case asked(id: UUID, from: LinkImp, to: UUID, text: String, by: UUID)
    /// The answer to a message one of our Imps sent.
    case answer(id: UUID, text: String, failed: Bool)
    /// A linked Mac took an Imp of ours in for good.
    case adopted(UUID)
}

/// The phone's side of Imp Link 2 (see `docs/LINK.md`): one `LinkNode` for this iPhone, and what
/// its devices say about the Imps visiting here (their looks, chats, work, moods, speeches, talks and
/// files). The Imps hatched here are `PocketRuntime`'s; the hub routes what the node hears to it.
@MainActor @Observable
final class LinkHub {
    nonisolated static let nameKey = "yourName"
    nonisolated static let serverKey = "serverAddress"

    /// The devices this iPhone is linked with.
    private(set) var links: [LinkRecord] = []
    /// The linked devices that are connected right now.
    private(set) var connectedPeers: [LinkDevice] = []
    /// Every device that is connected, linked or not (a visiting Imp's home may only be a visitor).
    private(set) var online: Set<UUID> = []
    /// The devices that are connected through the Hop (the internet), not the local network.
    private(set) var viaHop: Set<UUID> = []
    /// The Imps visiting this iPhone.
    private(set) var visits: [Visits.Visit] = []
    /// Imps hatched here that another device holds right now, and who holds each.
    private(set) var holders: [UUID: UUID] = [:]
    private(set) var chats: [UUID: [LinkTurn]] = [:]
    private(set) var work: [UUID: LinkWork] = [:]
    private(set) var moods: [UUID: Mood] = [:]
    /// What each visiting Imp is saying to another Imp (a bubble above it on the stage).
    private(set) var speeches: [UUID: LinkSpeech] = [:]
    /// What the home's chats say each visiting Imp talked about with other Imps (`requestTalks`).
    /// Not kept between launches.
    private(set) var talkLines: [UUID: [TalkLine]] = [:]
    /// Files from the homes of visiting Imps that replies show (pictures, voices, videos, documents).
    @ObservationIgnored private(set) lazy var files = LinkFileStore(hub: self)
    /// The name other devices see for this iPhone.
    private(set) var name: String
    /// A short message to show (a toss that didn't work out, a code that didn't read).
    var toast: String?

    @ObservationIgnored let node: LinkNode
    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored var onPocket: ((PocketEvent) -> Void)?
    /// Whether a game is on, which turns every thrown Imp away.
    @ObservationIgnored var isPlaying: () -> Bool = { false }
    /// The Imps on this screen, as the other devices are told.
    @ObservationIgnored private(set) var staged: [LinkStaged] = []

    @ObservationIgnored private var active = false
    @ObservationIgnored private var speechClear: [UUID: Task<Void, Never>] = [:]

    init() {
        let name = UserDefaults.standard.string(forKey: Self.nameKey) ?? UIDevice.current.name
        self.name = name
        var problem: String?
        do {
            node = try LinkNode(name: name, kind: .phone, storage: KeychainLinkStorage())
        } catch {
            // The saved links can't be read: carry on without them (nothing is written over them).
            problem = String(localized: "Imp couldn't read its links.")
            node = try! LinkNode(name: name, kind: .phone, storage: LinkMemoryStorage())
        }
        toast = problem
        node.setServer(UserDefaults.standard.string(forKey: Self.serverKey).flatMap(Self.hop))
        node.onEvent = { [weak self] in self?.handle($0) }
        refresh()
    }

    // MARK: This iPhone

    /// Changes the name other devices see.
    func rename(_ new: String) {
        node.rename(new)
        name = node.device.name
        UserDefaults.standard.set(name, forKey: Self.nameKey)
    }

    /// Sets (or clears, with empty text) the Imp server this iPhone waits at. False for text that isn't one.
    @discardableResult
    func setServer(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || ImpServer(text) != nil else { return false }
        UserDefaults.standard.set(text, forKey: Self.serverKey)
        node.setServer(Self.hop(text))
        return true
    }

    /// The server as written, or nil, as the address of its Hop.
    private nonisolated static func hop(_ text: String) -> HopAddress? {
        ImpServer(text).flatMap { HopAddress($0.hop) }
    }

    /// The Imp server this iPhone waits at, as last set (empty: none).
    var server: String { UserDefaults.standard.string(forKey: Self.serverKey) ?? "" }

    /// Where a model server on a linked Mac is reached from this phone: its name on the network
    /// (`.local` first). Nil when no Mac is linked.
    var macHost: String? {
        let hosts = links.first { $0.device.kind == .mac }?.routes.hosts ?? []
        return hosts.first { $0.hasSuffix(".local") } ?? hosts.first
    }

    // MARK: Lifecycle

    /// The app is in front (true) or not. The node only lives in the foreground.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            Task {
                await node.start()
                // Put away while it was starting.
                if !active { node.stop() }
                refresh()
            }
        } else {
            node.stop()
            refresh()
            for id in visits.map(\.id) { lost(visit: id) }
        }
    }

    /// Reads the node's books into what the views watch.
    func refresh() {
        func set<T: Equatable>(_ value: inout T, _ new: T) { if value != new { value = new } }
        set(&links, node.links)
        set(&connectedPeers, node.connectedPeers.sorted { $0.name < $1.name })
        set(&online, Set(node.connected))
        set(&viaHop, Set(node.connected.filter(node.isThroughHop)))
        set(&visits, node.visits.visits)
        set(&holders, Dictionary(node.away.entries.map { ($0.imp, $0.holder) }, uniquingKeysWith: { $1 }))
    }

    /// Imps hatched here that another device holds right now.
    var away: Set<UUID> { Set(holders.keys) }

    func isConnected(_ device: UUID) -> Bool { online.contains(device) }

    // MARK: Links

    /// Links with the device that showed `invite`, from a code that was scanned or opened. A failure
    /// is a toast; a success is announced when the node reports the link.
    func join(_ invite: LinkInvite) async {
        if !node.isRunning { await node.start() }
        do {
            _ = try await node.join(invite)
        } catch let error as LinkNode.JoinError {
            toast = switch error {
            case .notRunning: String(localized: "Imp is still starting. Try again.")
            case .itsOwnCode: String(localized: "That is this iPhone's own code.")
            case .keyChanged: String(localized: "That device is linked already, under another key. Forget it first.")
            case .full: String(localized: "This iPhone is linked with as many devices as it can be.")
            case .unreachable: String(localized: "Couldn't reach that device. Are you on the same network?")
            case .refused: String(localized: "That code has run out. Ask for a new one.")
            case .timedOut: String(localized: "That device didn't answer.")
            }
        } catch {
            toast = error.localizedDescription
        }
        refresh()
    }

    /// Reads a code (a link opened, scanned or pasted) and joins. False if it isn't a code from Imp.
    @discardableResult
    func join(code: String) -> Bool {
        guard let invite = LinkInvite(string: code) else { return false }
        Task { await join(invite) }
        return true
    }

    /// Ends the link with a device: the Imps it held come home and the ones visiting from it go home.
    func forget(_ device: UUID) {
        let name = deviceName(device)
        let result = node.forget(device)
        forgotten(result, forgetting: name)
    }

    /// Ends every link and makes a new door key, so every code shown before stops working.
    func forgetEveryone() {
        forgotten(node.forgetEveryone(), forgetting: nil)
    }

    /// Clears what a forgotten device left on the stage, and says what became of the Imps.
    private func forgotten(_ result: LinkNode.Forgotten, forgetting name: String?) {
        refresh()
        for imp in result.sentHome {
            clear(imp)
            onEvent?(.left(imp))
        }
        onEvent?(.roster)
        let moved = !result.calledHome.isEmpty || !result.sentHome.isEmpty
        if let name {
            toast = moved ? String(localized: "Forgot \(name). The Imps went home.") : String(localized: "Forgot \(name).")
        } else {
            toast = moved ? String(localized: "Forgot everyone. The Imps went home.") : String(localized: "Forgot everyone.")
        }
    }

    /// A device this one knows: a linked one, or the home of a visiting Imp.
    func device(_ id: UUID) -> LinkDevice? {
        links.first { $0.id == id }?.device ?? visits.first { $0.home.id == id }?.home.device
    }

    /// A linked device's name, or a stand-in once it's gone.
    func deviceName(_ id: UUID) -> String { device(id)?.name ?? String(localized: "another device") }

    /// The Imps on this screen changed: the other devices are told.
    func setStage(_ imps: [LinkStaged]) {
        staged = imps
        node.setStage(imps)
    }

    // MARK: Visiting Imps

    func visit(_ imp: UUID) -> Visits.Visit? { visits.first { $0.id == imp } }

    /// The Imps visiting here, with the device they think on.
    var visitors: [LinkStaged] { visits.map { LinkStaged(imp: $0.imp, home: $0.home.id) } }

    /// Whether a visiting Imp's home is connected. A visit whose home isn't sleeps.
    func isAwake(_ imp: UUID) -> Bool { visit(imp).map { online.contains($0.home.id) } ?? false }

    /// Sends a visiting Imp home from here: its body goes now and its home hears when it can be reached.
    func sendHome(_ imp: UUID) {
        guard node.sendHome(imp) else { return }
        clear(imp)
        refresh()
        onEvent?(.left(imp))
    }

    /// Takes one of our Imps back from the device that holds it.
    func callHome(_ imp: UUID) {
        node.callHome(imp)
        refresh()
        onEvent?(.roster)
    }

    // MARK: Doors

    /// Where an Imp goes when thrown off `side` at `height`.
    func door(of imp: UUID, side: LinkSide, height: Double) -> LinkDoors.Outcome {
        node.door(of: imp, side: side, height: height)
    }

    /// The side (the nearer one first) and height at which an Imp leaves for `device`, if a door leads there.
    func way(of imp: UUID, to device: UUID, preferring side: LinkSide) -> (side: LinkSide, height: Double)? {
        for side in [side, side.opposite] {
            if let band = node.bands(of: imp, side: side).first(where: { $0.device == device }) {
                return (side, (band.top + band.bottom) / 2)
            }
        }
        return nil
    }

    /// One device's share of a side, for labelling it while an Imp is carried.
    struct DoorLabel: Identifiable, Equatable {
        var device: LinkDevice
        /// The heights from `top` to `bottom` (0 is the top of the screen).
        var top: Double
        var bottom: Double
        /// The door an Imp that came to visit goes back through.
        var isBack: Bool
        var id: UUID { device.id }
    }

    /// The doors on a side of the screen for an Imp, top to bottom.
    func doors(of imp: UUID, side: LinkSide) -> [DoorLabel] {
        var back: UUID?
        if case .visit(let entry, let from) = node.travel(of: imp), entry == side { back = from }
        return node.bands(of: imp, side: side).compactMap { band in
            device(band.device).map { DoorLabel(device: $0, top: band.top, bottom: band.bottom, isBack: band.device == back) }
        }
    }

    /// What to tell the person when an Imp bounces off a side that leads nowhere.
    func hint(for imp: UUID, bounce: LinkDoors.Bounce, side: LinkSide) -> String {
        guard case .visit(let entry, let from) = node.travel(of: imp) else { return String(localized: "Nobody's on this side") }
        let back = deviceName(from)
        switch bounce {
        case .nobodyConnected: return String(localized: "Nobody's on this side")
        case .wayBackIsClosed: return String(localized: "\(back) isn't around")
        case .nowhereElse:
            return entry == .left ? String(localized: "Throw it back to the left to return it to \(back)")
                : String(localized: "Throw it back to the right to return it to \(back)")
        }
    }

    /// Throws an Imp (ours, or a visitor) to a connected device. False if it isn't there to catch it.
    func pass(_ imp: LinkImp, exit: StageEngine.Exit, to device: UUID) -> Bool {
        node.pass(imp, entry: .after(exit: exit.side, height: exit.height, speed: exit.speed), to: device) != nil
    }

    // MARK: Hearing the node

    private func handle(_ event: LinkNode.Event) {
        let before = links
        refresh()
        switch event {
        case .connected: break
        case .disconnected(let id):
            files.linkLost()
            for visit in visits where visit.home.id == id { lost(visit: visit.id) }
        case .linked(let device):
            toast = String(localized: "Linked with \(device.name)")
        case .forgotten(let id):
            let who = before.first { $0.id == id }?.device.name ?? String(localized: "A device")
            toast = String(localized: "\(who) forgot this iPhone")
        case .message(let message, let from):
            receive(message, from: from)
        case .passed(let passed):
            finish(passed)
        case .problem(let problem):
            self.problem(problem)
        }
    }

    private func problem(_ problem: LinkNode.Problem) {
        switch problem {
        case .refused(let id): toast = String(localized: "\(deviceName(id)) doesn't know this iPhone any more. Link again.")
        case .keyChanged(let id): toast = String(localized: "\(deviceName(id)) isn't the device it was linked as.")
        case .inviteRefused: toast = String(localized: "That code has run out. Ask for a new one.")
        case .full: toast = String(localized: "Imp is at its limit of links or visiting Imps.")
        case .listener, .storage, .badProof, .hop: break
        }
    }

    private func receive(_ message: LinkMessage, from: UUID) {
        switch message {
        case .pass(let transfer, let imp, let entry, _, _):
            // A game is on: nobody can come in.
            guard !isPlaying() else { return node.decline(transfer, reason: .playing) }
            guard node.accept(transfer) else { return }
            refresh()
            onEvent?(.arrived(imp, entry))
        case .adopt(let transfer, _, _, _, _):
            // Imps move in for good on a Mac.
            node.decline(transfer, reason: .other)
        case .claim(let imp, _):
            onPocket?(.claimed(imp))
            onEvent?(.left(imp))
        case .release:
            onEvent?(.roster)
        case .gone(let imp):
            clear(imp)
            onEvent?(.left(imp))
        case .ask(let imp, let text): onPocket?(.ask(imp, text))
        case .stop(let imp): onPocket?(.stop(imp))
        case .newChat(let imp): onPocket?(.newChat(imp))
        case .felt(let imp, let feeling): onPocket?(.felt(imp, feeling))
        case .file(let id, let imp, _): onPocket?(.file(id: id, imp: imp, from: from))
        case .talks(let imp): onPocket?(.talks(imp, from: from))
        case .message(let id, let imp, let to, _, let text, _):
            onPocket?(.asked(id: id, from: imp, to: to, text: text, by: from))
        case .answer(let id, let text, let failed): onPocket?(.answer(id: id, text: text, failed: failed))
        case .look: onEvent?(.roster)
        case .chat(let imp, let turns): chats[imp] = turns
        case .work(let imp, let w): work[imp] = w
        case .mood(let imp, let name): moods[imp] = Mood(link: name)
        case .animate(let imp, let beats): onEvent?(.animate(imp, beats))
        case .speech(let imp, let speech): heard(speech, from: imp)
        case .filePart(let id, let part): files.received(part, for: id)
        case .fileFailed(let id, let reason): files.failed(id, reason: reason)
        case .talkLines(let imp, let lines): talkLines[imp] = lines
        default: break
        }
    }

    /// A thrown Imp was taken or came back.
    private func finish(_ passed: LinkNode.Passed) {
        let to = deviceName(passed.to)
        switch (passed.kind, passed.outcome) {
        case (.pass, .took):
            clear(passed.imp)
            onEvent?(.left(passed.imp))
        case (.adopt, .took):
            onPocket?(.adopted(passed.imp))
        case (_, .declined(let reason)):
            let why = switch reason {
            case .full: String(localized: "\(to) has no room for another Imp")
            case .playing: String(localized: "\(to) is playing a game")
            case .notLinked: String(localized: "\(to) doesn't know this iPhone")
            case .timeout: String(localized: "\(to) didn't answer")
            case .other: String(localized: "\(to) didn't take it")
            }
            onEvent?(.refused(passed.imp, why))
        }
    }

    // MARK: Asking a visiting Imp's home

    func ask(_ imp: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let home = visit(imp)?.home.id else { return }
        node.send(.ask(imp: imp, text: text), to: home)
    }

    func stop(_ imp: UUID) { tell(imp, .stop(imp: imp)) }
    func felt(_ imp: UUID, _ feeling: LinkFeeling) { tell(imp, .felt(imp: imp, feeling: feeling)) }

    /// Asks the home what the Imp has said with other Imps; the answer lands in `talkLines`.
    func requestTalks(_ imp: UUID) { tell(imp, .talks(imp: imp)) }

    func newChat(_ imp: UUID) {
        chats[imp] = []
        tell(imp, .newChat(imp: imp))
    }

    /// Asks the home for a file (see `LinkFileStore`).
    func requestFile(_ transfer: UUID, imp: UUID, ref: String) -> Bool {
        guard let home = visit(imp)?.home.id else { return false }
        return node.send(.file(id: transfer, imp: imp, ref: ref), to: home)
    }

    private func tell(_ imp: UUID, _ message: LinkMessage) {
        if let home = visit(imp)?.home.id { node.send(message, to: home) }
    }

    // MARK: Speech

    /// Hides a speech bubble (tapped away).
    func dismissSpeech(_ imp: UUID) {
        if let speech = speeches[imp] { drop(speech, for: imp) }
    }

    /// Takes a bubble off the stage for good, and its voices with it.
    private func drop(_ speech: LinkSpeech, for id: UUID) {
        speechClear[id]?.cancel()
        speechClear[id] = nil
        speeches[id] = nil
        StageVoice.shared.drop(owner: speech.id.uuidString)
    }

    /// The home's bubble came or went. One that goes stays a little longer here, long enough to read
    /// (the home hides its bubbles on its own clock, and you may only just have looked), and while
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

    /// A visiting Imp's home went out of reach: what it was saying can't go on (a question waiting for
    /// its answer leaves the stage; a reply stays up to be read, then goes the way it would have).
    private func lost(visit id: UUID) {
        guard let speech = speeches[id] else { return }
        if speech.role == .reply { heard(nil, from: id) } else { drop(speech, for: id) }
    }

    /// Forgets what was known of a visiting Imp that left.
    private func clear(_ imp: UUID) {
        chats[imp] = nil; work[imp] = nil; moods[imp] = nil; talkLines[imp] = nil
        if let speech = speeches[imp] { drop(speech, for: imp) }
    }
}
