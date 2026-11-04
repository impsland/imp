import Foundation
import ImpKit
import Observation
import SwiftUI
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
    /// `trusted`: the holder is one of the owner's own devices, so the Imp may use its tools.
    case ask(UUID, String, trusted: Bool)
    case stop(UUID)
    case newChat(UUID)
    case felt(UUID, LinkFeeling)
    case file(id: UUID, imp: UUID, from: UUID)
    case talks(UUID, from: UUID)
    /// A device became the holder of one of our Imps: it needs to hear how it looks and what it's doing.
    case claimed(UUID)
    /// A message between Imps: an Imp of ours is asked something by an Imp of another device.
    /// `trusted`: the asker's home is this iPhone or a trusted device, so the Imp may use its tools.
    case asked(id: UUID, from: LinkImp, to: UUID, text: String, by: UUID, trusted: Bool)
    /// The answer to a message one of our Imps sent.
    case answer(id: UUID, text: String, failed: Bool)
    /// A linked Mac took an Imp of ours in for good.
    case adopted(UUID)
    /// A Mac turned an Imp of ours down (it is back), or didn't answer: `sure` says whether it said no.
    case notAdopted(UUID, by: UUID, sure: Bool)
    /// A linked device connected, and its stage has been (or is about to be) told.
    case connected(UUID)
    /// The stage of a device changed (it is in `LinkNode.stage(of:)`).
    case stage(UUID)
    /// A device is no longer linked.
    case lost(UUID)
}

/// The phone's side of Imp Link 2 (see `docs/LINK.md`): one `LinkNode` for this iPhone, and what
/// its devices say about the Imps visiting here (their looks, chats, work, moods, speeches, talks and
/// files). The Imps hatched here are `PocketRuntime`'s; the hub routes what the node hears to it.
@MainActor @Observable
final class LinkHub {
    nonisolated static let nameKey = "yourName"
    nonisolated static let serverKey = "serverAddress"
    /// Set once the person has used linking (showed or scanned a code, or linked a device). Until
    /// then the node stays down, so iOS doesn't ask for the Local Network before it's needed.
    nonisolated static let networkKey = "usedLocalNetwork"

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
    /// Visiting Imps whose homes said they have no brain to think with (`LinkMessage.brain`): they sleep here.
    private(set) var brainless: Set<UUID> = []
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
    /// The last Imp a shake sent and how it went (see `ShakeSend.swift`).
    var shakeReceipt: ShakeReceipt?
    /// The last time each device was connected over the local network, for "was nearby lately".
    @ObservationIgnored private var lastNearby: [UUID: Date] = [:]
    @ObservationIgnored private var receiptClear: Task<Void, Never>?

    /// This iPhone's node. While the saved links can't be read (`isLocked`) it is a stand-in that never
    /// starts and writes nothing, so no new identity is made over the real one.
    @ObservationIgnored private(set) var node: LinkNode
    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored var onPocket: ((PocketEvent) -> Void)?
    /// Whether a game's card is up, which turns every thrown Imp away.
    @ObservationIgnored var isPlaying: () -> Bool = { false }
    /// The Imps on this screen, as the other devices are told.
    @ObservationIgnored private(set) var staged: [LinkStaged] = []

    /// The app is in front or only inactive (Control Center, a permission prompt), not in the background.
    @ObservationIgnored private var foreground = true
    /// The saved links couldn't be read (the Keychain isn't open before the first unlock): the hub stays
    /// offline and tries again when protected data is available.
    private(set) var isLocked = false
    @ObservationIgnored private var unlockWatch: Task<Void, Never>?
    @ObservationIgnored private var speechClear: [UUID: Task<Void, Never>] = [:]

    init() {
        let name = UserDefaults.standard.string(forKey: Self.nameKey) ?? UIDevice.current.name
        self.name = name
        if let real = try? LinkNode(name: name, kind: .phone, storage: KeychainLinkStorage()) {
            node = real
        } else {
            // The saved links can't be read: carry on without them, offline (nothing is written over them).
            node = try! LinkNode(name: name, kind: .phone, storage: LinkMemoryStorage())
            isLocked = true
            toast = String(localized: "Imp couldn't read its links yet. It tries again when your iPhone is unlocked.")
            unlockWatch = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                    guard let self else { return }
                    if unlock() { return }
                }
            }
        }
        wire()
        refresh()
    }

    /// Sets the node up: the server it waits at and where it reports.
    private func wire() {
        node.setServer(UserDefaults.standard.string(forKey: Self.serverKey).flatMap(Self.hop))
        node.onEvent = { [weak self] in self?.handle($0) }
    }

    /// Tries the saved links again. True once they are read and the real node has taken over.
    @discardableResult
    private func unlock() -> Bool {
        guard isLocked else { return true }
        guard let real = try? LinkNode(name: name, kind: .phone, storage: KeychainLinkStorage()) else { return false }
        node.onEvent = nil
        node = real
        isLocked = false
        unlockWatch?.cancel()
        unlockWatch = nil
        wire()
        node.setStage(staged)
        refresh()
        onEvent?(.roster)
        if foreground { start() }
        return true
    }

    /// Whether linking has been used: a device is linked, or a code was shown or scanned before.
    private var wantsNetwork: Bool { UserDefaults.standard.bool(forKey: Self.networkKey) || !node.links.isEmpty }

    private func start() {
        guard !isLocked, wantsNetwork else { return }
        Task {
            await node.start()
            // Put away while it was starting.
            if !foreground { node.stop() }
            refresh()
        }
    }

    /// Brings the node up for something that needs the local network (showing a code, linking). This
    /// is what makes iOS ask for the Local Network permission, and it is remembered so the node comes
    /// up by itself on later launches.
    func useNetwork() async {
        UserDefaults.standard.set(true, forKey: Self.networkKey)
        if isLocked { unlock() }
        guard !isLocked, !node.isRunning else { return }
        await node.start()
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

    /// The app's scene changed. The node lives in the foreground: it starts when the app is active
    /// and stops only in the background. Inactive (Control Center, the camera prompt) changes nothing.
    func setScene(_ phase: ScenePhase) {
        switch phase {
        case .active:
            foreground = true
            if isLocked { unlock() }
            if !node.isRunning { start() }
        case .inactive:
            break
        case .background:
            guard foreground || node.isRunning else { return }
            foreground = false
            node.stop()
            refresh()
            for id in visits.map(\.id) { lost(visit: id) }
        @unknown default:
            break
        }
    }

    /// Reads the node's books into what the views watch.
    func refresh() {
        func set<T: Equatable>(_ value: inout T, _ new: T) { if value != new { value = new } }
        set(&links, node.links)
        set(&connectedPeers, node.connectedPeers.sorted { $0.name < $1.name })
        set(&online, Set(node.connected))
        set(&viaHop, Set(node.connected.filter(node.isThroughHop)))
        let now = Date()
        for id in online.subtracting(viaHop) { lastNearby[id] = now }
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
        UserDefaults.standard.set(true, forKey: Self.networkKey)
        if isLocked { unlock() }
        guard !isLocked else {
            toast = String(localized: "Imp can't open its links until your iPhone has been unlocked.")
            return
        }
        if !node.isRunning { await node.start() }
        // Only the foreground keeps the node running: started while inactive, it must not outlive that.
        defer {
            if !foreground, node.isRunning { node.stop() }
            refresh()
        }
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
        onPocket?(.lost(device))
    }

    /// Ends every link and makes a new door key, so every code shown before stops working.
    func forgetEveryone() {
        let everyone = links.map(\.id)
        forgotten(node.forgetEveryone(), forgetting: nil)
        for id in everyone { onPocket?(.lost(id)) }
    }

    /// Marks a linked device as one of your own (or not): its Imps' requests may then use the tools of
    /// the Imps hatched here. Off for every device until you say so.
    func setTrusted(_ device: UUID, _ on: Bool) {
        node.setTrusted(device, on)
        refresh()
    }

    func isTrusted(_ device: UUID) -> Bool { node.isTrusted(device) }

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

    /// Whether a visiting Imp can think: its home is connected and has a brain for it (the same rule
    /// as on the Mac). One that can't sleeps.
    func wakefulness(_ imp: UUID) -> Wakefulness {
        guard let visit = visit(imp) else { return .homeAway }
        return .visiting(homeConnected: online.contains(visit.home.id), homeSaysReady: !brainless.contains(imp))
    }

    func isAwake(_ imp: UUID) -> Bool { wakefulness(imp).isAwake }

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
        // Every band is a door `door(of:side:height:)` leads through, so every band is labelled: a device
        // whose name isn't known yet (it is connected, but hasn't introduced itself) gets a stand-in.
        return node.bands(of: imp, side: side).map { band in
            let known = device(band.device)
                ?? LinkDevice(id: band.device, name: String(localized: "another device"), kind: .phone, key: Data())
            return DoorLabel(device: known, top: band.top, bottom: band.bottom, isBack: band.device == back)
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

    // MARK: Shaking

    /// The devices a shake may consider: the connected, linked ones, with how near each is.
    func shakePeers() -> [ShakeTransfer.Peer] {
        let linked = Set(links.map(\.id))
        return connectedPeers.map { device in
            ShakeTransfer.Peer(id: device.id, name: device.name, linked: linked.contains(device.id), connected: isConnected(device.id),
                               viaHop: viaHop.contains(device.id), lastNearby: lastNearby[device.id], mine: isTrusted(device.id))
        }
    }

    /// A shake started sending `imp` to `device`.
    func shakeBegan(_ imp: LinkImp, to device: UUID) {
        receiptClear?.cancel()
        shakeReceipt = ShakeReceipt(imp: imp.id, impName: imp.name, device: device, deviceName: deviceName(device), state: .sending)
    }

    /// It did not go (nobody there to catch it).
    func shakeFailed(_ imp: UUID) {
        guard shakeReceipt?.imp == imp else { return }
        shakeReceipt = nil
    }

    /// The person took it back within the few seconds they have.
    func undoShake() {
        guard let receipt = shakeReceipt, receipt.state == .arrived else { return }
        receiptClear?.cancel()
        shakeReceipt = nil
        callHome(receipt.imp)
        let text = String(localized: "\(receipt.impName) came back")
        toast = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// The receipt stays for a few seconds after the Imp arrived, then goes.
    private func shakeArrived(_ imp: UUID) {
        guard var receipt = shakeReceipt, receipt.imp == imp else { return }
        receipt.state = .arrived
        shakeReceipt = receipt
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "\(receipt.impName) is on \(receipt.deviceName). Undo is available."))
        receiptClear?.cancel()
        receiptClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShakeReceipt.undoSeconds))
            guard !Task.isCancelled, self?.shakeReceipt?.imp == imp else { return }
            self?.shakeReceipt = nil
        }
    }

    // MARK: Hearing the node

    private func handle(_ event: LinkNode.Event) {
        let before = links
        refresh()
        switch event {
        case .connected(let device, _): onPocket?(.connected(device.id))
        case .disconnected(let id):
            files.linkLost()
            for visit in visits where visit.home.id == id { lost(visit: visit.id) }
        case .linked(let device):
            toast = String(localized: "Linked with \(device.name)")
        case .forgotten(let id, let result):
            // Their Imps visiting here go home (their bodies go); ours they held are home again.
            for imp in result.sentHome {
                clear(imp)
                onEvent?(.left(imp))
            }
            onPocket?(.lost(id))
            onEvent?(.roster)
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
        case .ask(let imp, let text): onPocket?(.ask(imp, text, trusted: node.isTrusted(message, from: from)))
        case .stage: onPocket?(.stage(from))
        case .stop(let imp): onPocket?(.stop(imp))
        case .newChat(let imp): onPocket?(.newChat(imp))
        case .felt(let imp, let feeling): onPocket?(.felt(imp, feeling))
        case .file(let id, let imp, _): onPocket?(.file(id: id, imp: imp, from: from))
        case .talks(let imp): onPocket?(.talks(imp, from: from))
        case .message(let id, let imp, let to, _, let text, _):
            onPocket?(.asked(id: id, from: imp, to: to, text: text, by: from, trusted: node.isTrusted(message, from: from)))
        case .answer(let id, let text, let failed): onPocket?(.answer(id: id, text: text, failed: failed))
        case .look: onEvent?(.roster)
        case .chat(let imp, let turns): chats[imp] = turns
        case .work(let imp, let w): work[imp] = w
        case .mood(let imp, let name): moods[imp] = Mood(link: name)
        case .brain(let imp, let ready): if ready { brainless.remove(imp) } else { brainless.insert(imp) }
        case .animate(let imp, let beats): onEvent?(.animate(imp, beats))
        case .speech(let imp, let speech): heard(speech, from: imp)
        case .filePart(let id, let part): files.received(part, for: id, from: from)
        case .fileFailed(let id, let reason): files.failed(id, reason: reason, from: from)
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
            shakeArrived(passed.imp)
        case (.adopt, .took):
            onPocket?(.adopted(passed.imp))
        case (.adopt, .declined(let reason)):
            // Only a no is one. No answer may mean it was taken: the Mac's stage tells next time we meet.
            onPocket?(.notAdopted(passed.imp, by: passed.to, sure: reason != .timeout))
        case (_, .declined(let reason)):
            let why = switch reason {
            case .full: String(localized: "\(to) has no room for another Imp")
            case .playing: String(localized: "\(to) is playing a game")
            case .notLinked: String(localized: "\(to) doesn't know this iPhone")
            case .timeout: String(localized: "\(to) didn't answer")
            case .other: String(localized: "\(to) didn't take it")
            }
            if shakeReceipt?.imp == passed.imp {
                shakeFailed(passed.imp)
                UIAccessibility.post(notification: .announcement, argument: why)
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
    /// Returns the home it was asked of, which is the only device whose parts count.
    func requestFile(_ transfer: UUID, imp: UUID, ref: String) -> UUID? {
        guard let home = visit(imp)?.home.id, node.send(.file(id: transfer, imp: imp, ref: ref), to: home) else { return nil }
        return home
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
        chats[imp] = nil; work[imp] = nil; moods[imp] = nil; talkLines[imp] = nil; brainless.remove(imp)
        if let speech = speeches[imp] { drop(speech, for: imp) }
    }
}
