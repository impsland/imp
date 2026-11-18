import Foundation
import ImpCore
import ImpKit
import Observation

/// The Imps hatched on this iPhone, alive: each thinks here, with its own service and tools, one ask
/// at a time, wherever its body is. They message each other directly, and the Imps of other devices
/// through the link. An Imp thrown to another device is still at home here: its holder asks it things
/// and hears back. Moving one to a Mac for good is an explicit move the Mac has to confirm.
@MainActor @Observable
final class PocketRuntime {
    private struct Failure: LocalizedError, Sendable {
        var errorDescription: String?
        /// The other device answered with it (it failed there, or nobody answered in time), so the question was asked.
        var isAnswer = false
        init(_ text: String, isAnswer: Bool = false) { errorDescription = text; self.isAnswer = isAnswer }
    }

    /// Something an Imp has to do, after what it's doing now. `abort` says so if the Imp goes before its turn.
    private struct Job {
        /// The device that asked, if another did: its share of the queue is capped too.
        var device: UUID?
        var run: @MainActor () async -> Void
        var abort: @MainActor () -> Void
    }

    /// How many jobs one Imp may have queued (or running), and one remote device in all.
    private static let queueLimit = 5

    /// Pocket Imps carry no animations of their own (there are no preset ones), so they get no play tool.
    private static let animations: [String] = []

    private let store: PocketStore
    /// What these Imps asked Imps on other devices: the answerer files it there, so this iPhone keeps its own copy.
    private let asked: AskedTalks
    private(set) var work: [UUID: LinkWork] = [:]
    /// What each pocket Imp is saying to another Imp (a bubble above it on the stage), like the
    /// visiting Imps' in `LinkHub.speeches`.
    private(set) var speeches: [UUID: LinkSpeech] = [:]
    /// What each pocket Imp acted out last (`StageEvent.animate`).
    private(set) var acts: [UUID: Performance] = [:]

    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored private let hub: LinkHub
    @ObservationIgnored private var brain: PocketBrain
    /// How long a request may take and how it is retried. Kept in UserDefaults (`RequestLimits.Key`).
    private(set) var limits = ImpKit.RequestLimits.stored()
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [UUID: [Job]] = [:]
    @ObservationIgnored private var queuedBy: [UUID: Int] = [:]
    /// Imps on their way to a Mac for good: off the stage and not askable until the Mac says it has
    /// them or says no, and, if it doesn't answer, until the next time that Mac's stage is seen.
    private(set) var moving: [UUID: UUID] = [:]
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<String, Error>] = [:]
    /// How many messages each pocket Imp sent without waiting that have no answer yet (`troupe::may_leave` caps it).
    /// Not saved: an answer on its way is lost with the app, like on the Mac.
    @ObservationIgnored private var unanswered: [UUID: Int] = [:]
    @ObservationIgnored private var speechClear: [UUID: Task<Void, Never>] = [:]

    init(hub: LinkHub, store: PocketStore = PocketStore()) {
        self.hub = hub
        self.store = store
        asked = AskedTalks(file: store.askedTalksFile)
        brain = PocketBrain(secrets: store.secrets, limits: ImpKit.RequestLimits.stored())
        hub.onPocket = { [weak self] in self?.heard($0) }
    }

    /// Keeps new request limits and uses them from the next request on, no restart needed.
    func setLimits(_ new: ImpKit.RequestLimits) {
        let clamped = new.clamped
        guard clamped != limits else { return }
        limits = clamped.store()
        brain = PocketBrain(secrets: store.secrets, limits: clamped)
    }

    // MARK: The Imps

    var imps: [PocketImp] { store.imps }
    var looks: [LinkImp] { store.imps.map(\.look) }
    var secrets: any PocketSecrets { store.secrets }

    func contains(_ id: UUID) -> Bool { store.contains(id) }

    /// What the Imps hatched here said to each other (and were asked by Mac Imps), from their chats.
    /// What the Imps here said with other Imps: what they were asked (in their chats) and what they asked Imps on
    /// other devices (`AskedTalks`).
    var talkLines: [TalkLine] {
        store.imps.flatMap { imp in
            TalkLog.lines(answeredBy: ChatTurn.Sender(id: imp.id, name: imp.name, hue: imp.hue), in: imp.chats)
        } + asked.lines
    }

    /// A linked Mac's name on the network (`.local` first): where a model server on the Mac is
    /// reached from this phone. Nil when no Mac is linked.
    var macHost: String? { hub.macHost }

    func isMoving(_ id: UUID) -> Bool { moving[id] != nil }

    func hasBrain(_ id: UUID) -> Bool {
        !isMoving(id) && store.imp(id).map { (try? $0.validate()) != nil } ?? false
    }

    /// What the Imp is told about itself, for the first run's hello.
    func personality(of id: UUID) -> String { store.imp(id)?.personality ?? "" }

    /// Keeps the Brain the first run checked: its key goes to the Keychain and nowhere else.
    /// Throws `KeyNotSaved` when the Keychain refuses the key, and then nothing is changed.
    func adoptFirstRunBrain(_ brain: FirstRunBrain, for id: UUID) throws {
        if !brain.key.isEmpty {
            do { try store.secrets.set(brain.key, .apiKey, imp: id) } catch { throw KeyNotSaved() }
        } else {
            store.secrets.remove(.apiKey, imp: id)
        }
        edit(id) { $0.brain = PocketService(brain) }
    }

    func hatch(_ imp: PocketImp) {
        store.add(imp)
    }

    /// The Brain a new Imp starts with, as on the Mac: the one the newest Imp that thinks here uses.
    var defaultBrainImp: PocketImp? { store.imps.last { hasBrain($0.id) } }

    /// The size a new Imp starts with.
    static let newSize = 1.0
    /// The colours an Imp can wear.
    static let hues: [Double] = [0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.9]

    /// Hatches a new Imp at once, ready to talk: a fresh name and colour, and the default Brain with its key
    /// (copied in the Keychain, so each Imp keeps its own). With no Brain anywhere yet it sleeps until it gets one.
    /// Returns its id and whether it has a Brain.
    @discardableResult
    func hatchReady() -> (id: UUID, awake: Bool) {
        let names = store.imps.map(\.name)
        var imp = PocketImp(name: ImpProfile.randomName(avoiding: names),
                            hue: Self.hues.filter { hue in !store.imps.contains { abs($0.hue - hue) < 0.02 } }.randomElement()
                                ?? Self.hues.randomElement() ?? ImpProfile.defaultHue,
                            scale: Self.newSize)
        if let source = defaultBrainImp {
            let key = store.secrets.get(.apiKey, imp: source.id)
            // A key that can't be copied leaves the new Imp asleep rather than thinking without it.
            if key.map({ (try? store.secrets.set($0, .apiKey, imp: imp.id)) != nil }) ?? true {
                imp.brain = source.brain
            }
        }
        hatch(imp)
        return (imp.id, hasBrain(imp.id))
    }

    func edit(_ id: UUID, _ change: (inout PocketImp) -> Void) {
        store.update(id, change)
        if let look = store.imp(id)?.look { tell(id, .look(imp: look)) }
        tellBrain(id)
    }

    /// Deletes an Imp. If another device holds it, it is called home first so that device lets go.
    func delete(_ id: UUID) {
        guard !isMoving(id) else { return }
        hub.node.callHome(id)
        hub.refresh()
        forget(id)
    }

    /// The Imp is gone (deleted, or taken in by a Mac): what it was doing stops, what waited for it
    /// is told it isn't around, and nothing of it stays on the stage.
    private func forget(_ id: UUID) {
        store.remove(id)
        asked.forget(imp: id)
        moving[id] = nil
        let dropped = waiting.removeValue(forKey: id) ?? []
        for job in dropped { release(job) }
        running[id]?.cancel()
        work[id] = nil
        acts[id] = nil
        if let speech = speeches[id] { dismiss(speech, for: id) }
        for job in dropped { job.abort() }
    }

    // MARK: Moving in for good

    /// Moves `id` to the linked Mac `device` for good. It stays here until the Mac says it has it
    /// (`PocketEvent.adopted`), which it only does once its user agreed.
    func move(_ id: UUID, exit: StageEngine.Exit, to device: UUID) {
        guard let imp = store.imp(id) else {
            onEvent?(.refused(id, String(localized: "That Imp isn't on this iPhone.")))
            return
        }
        // Its answer would be lost on the way: it has to finish first.
        guard moving[id] == nil else { return }
        guard running[id] == nil, (waiting[id] ?? []).isEmpty else {
            onEvent?(.refused(id, String(localized: "\(imp.name) is busy thinking. Move it once it's done.")))
            return
        }
        // Not askable from here on, so the kit taken below is the one that arrives.
        moving[id] = device
        do {
            let (kit, secrets) = try imp.adoption(secrets: store.secrets)
            let entry = LinkEntry.after(exit: exit.side, height: exit.height, speed: exit.speed)
            guard hub.node.adopt(id, kit: kit, secrets: secrets, entry: entry, to: device) != nil else {
                throw Failure(String(localized: "\(hub.deviceName(device)) isn't around"))
            }
        } catch {
            moving[id] = nil
            onEvent?(.refused(id, error.localizedDescription))
        }
    }

    /// The Mac has the Imp, said no, or (`sure` false) didn't say.
    private func settle(_ id: UUID, by device: UUID, sure: Bool) {
        guard moving[id] == device else { return }
        guard sure else { return }  // decided when that Mac's stage is next seen
        moving[id] = nil
        onEvent?(.refused(id, String(localized: "\(hub.deviceName(device)) didn't take it")))
        onEvent?(.roster)
    }

    /// A Mac's stage is known again: an Imp it didn't answer for is there (it is the Mac's now) or isn't (back).
    private func decide(movesTo device: UUID) {
        let there = Set(hub.node.stage(of: device).filter { $0.home == device }.map(\.imp.id))
        for (id, mac) in moving where mac == device {
            if there.contains(id) {
                forget(id)
                hub.refresh()
                onEvent?(.left(id))
            } else {
                moving[id] = nil
                onEvent?(.refused(id, String(localized: "\(hub.deviceName(device)) didn't take it")))
                onEvent?(.roster)
            }
        }
    }

    // MARK: Asking

    /// Runs `job` after what the Imp is already doing.
    /// False (nothing queued) when the Imp, or the device asking, already has as much as it may.
    @discardableResult
    private func enqueue(_ id: UUID, from device: UUID? = nil, abort: @escaping @MainActor () -> Void = {},
                         _ run: @escaping @MainActor () async -> Void) -> Bool {
        guard !isMoving(id), (waiting[id]?.count ?? 0) + (running[id] == nil ? 0 : 1) < Self.queueLimit,
              device.map({ (queuedBy[$0] ?? 0) < Self.queueLimit }) ?? true else { return false }
        if let device { queuedBy[device, default: 0] += 1 }
        waiting[id, default: []].append(Job(device: device, run: run, abort: abort))
        if running[id] == nil { next(id) }
        return true
    }

    private func release(_ job: Job) {
        guard let device = job.device else { return }
        queuedBy[device] = max(0, (queuedBy[device] ?? 1) - 1)
        if queuedBy[device] == 0 { queuedBy[device] = nil }
    }

    private func next(_ id: UUID) {
        guard !(waiting[id] ?? []).isEmpty else {
            running[id] = nil
            waiting[id] = nil
            return
        }
        let job = waiting[id]!.removeFirst()
        running[id] = Task { await job.run(); release(job); next(id) }
    }

    /// One ask, from you or from another Imp: thinks, files the turn in its chat.
    /// `limitedTo` names the device asking when this iPhone doesn't count it as the owner's: no tools then.
    private func answer(_ text: String, of id: UUID, from sender: ChatTurn.Sender? = nil, limitedTo device: String? = nil,
                        turnID: UUID? = nil, answered: (event: String, from: ChatTurn.Sender)? = nil, depth: Int = 0) async throws -> PocketAnswer {
        guard let imp = store.imp(id) else { throw Failure(String(localized: "That Imp isn't on this iPhone.")) }
        let result = try await brain.ask(text, of: imp, from: sender, talk: talk(for: imp, depth: depth), limitedTo: device.map { ($0, hub.name) },
                                         turnID: turnID, answered: answered) { [weak self] work in
            await self?.report(work, for: id)
        }
        store.update(id) { $0.record(result) }
        pushChat(id)
        return result
    }

    private func report(_ work: LinkWork?, for id: UUID) {
        self.work[id] = work
        pushWork(id)
    }

    // MARK: Messaging

    /// `depth`: how many answers deep the turn is that uses it (0: you or another device asked).
    private func talk(for imp: PocketImp, depth: Int = 0) -> PocketTalk {
        let id = imp.id
        let me = hub.node.device.id
        let here = store.imps.filter { hasBrain($0.id) }.map { LinkStaged(imp: $0.look, home: me) }
        // Imps on other devices may share a name with one here or with this one: `TalkNames` gives each
        // its own (`Pip@Studio`), so every one stays reachable.
        let all = targets(of: id, here: here)
        let talkNames = TalkNames(sender: imp.name, here: all.filter { $0.home == me }, name: \.imp.name,
                                  away: all.filter { $0.home != me }, awayName: \.imp.name, place: { hub.deviceName($0.home) })
        let named = talkNames.here + talkNames.away
        // What each says about itself. What another device sent is sanitized again.
        let profiles = named.map { ImpAbilities.profile(name: $0.name, about: $0.imp.imp.about, abilities: $0.imp.imp.abilities) }
        return PocketTalk(others: named.map(\.name), send: { [weak self] to, text in
            guard let self else { throw CancellationError() }
            return try await self.deliver(text, to: to, from: id, among: named)
        }, animations: Self.animations, play: nil, profiles: profiles, later: { [weak self] to, text in
            guard let self else { throw CancellationError() }
            return try await self.deliverLater(text, to: to, from: id, among: named, depth: depth)
        })
    }

    /// The Imps `id` can message: those of this iPhone, the ones on the screen its body is on, the ones
    /// out on the owner's other devices (marked Mine), and the visitors on this iPhone's screen while it is
    /// away (their homes let this iPhone, their holder, ask for its own Imps).
    private func targets(of id: UUID, here: [LinkStaged]) -> [LinkStaged] {
        let body = hub.node.holder(of: id).map { hub.node.stage(of: $0) + hub.staged } ?? hub.staged
        let stage = body + hub.node.onMyOtherDevices
        return LinkTalks.targets(of: id, mine: here, stage: stage)
    }

    private func deliver(_ text: String, to name: String, from id: UUID, among targets: [(name: String, imp: LinkStaged)]) async throws -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sender = store.imp(id), let target = targets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })?.imp else {
            throw Failure(String(localized: "\(name) isn't around"))
        }
        let asking = say(.asking, to: target.imp.name, hue: target.imp.hue, text, for: id)
        defer { unsay(asking, for: id) }
        if let other = store.imp(target.id), target.home == hub.node.device.id {
            return try await asked(other, text, from: ChatTurn.Sender(id: sender.id, name: sender.name, hue: sender.hue))
        }
        // Its answer is filed on the other device: this iPhone keeps a copy, for this Imp's Talks.
        let message = UUID(), date = Date()
        let me = ChatTurn.Sender(id: sender.id, name: sender.name, hue: sender.hue)
        let them = ChatTurn.Sender(id: target.imp.id, name: target.imp.name, hue: target.imp.hue)
        func keep(_ reply: String, failed: Bool) {
            asked.record(TalkLine(id: message, date: date, asker: me, answerer: them, question: text, reply: reply, failed: failed))
        }
        do {
            let reply = try await askAway(target, text, from: sender.look, id: message)
            keep(reply, failed: false)
            return reply
        } catch let failure as Failure where failure.isAnswer {
            keep(failure.localizedDescription, failed: true)
            throw failure
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Sends without waiting: the receipt comes back at once and the answer later, as a turn of the sender's own
    /// (`ChatTurn.Via.answer`) through its job queue: at once if it is idle, else after what it is doing. The answer is
    /// dropped when the sender is gone or has moved to another device (it thinks there). `depth` is the sender's turn's.
    private func deliverLater(_ text: String, to name: String, from id: UUID, among targets: [(name: String, imp: LinkStaged)], depth: Int) async throws -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.contains(id), let target = targets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })?.imp else {
            throw Failure(String(localized: "\(name) isn't around"))
        }
        let count = unanswered[id] ?? 0
        if let refusal = ImpCore.troupeMayLeave(pending: UInt32(count), depth: UInt32(depth)) { throw Failure(refusal) }
        let task = ImpCore.troupeTaskLabel(id: UUID().uuidString)
        let sent = Self.clock.string(from: Date())
        let from = ChatTurn.Sender(id: target.imp.id, name: target.imp.name, hue: target.imp.hue)
        unanswered[id] = count + 1
        Task { [weak self] in
            guard let self else { return }
            var reply: String, failed = false
            do {
                // Another device answers within the link's own time. An Imp here answers within the core's.
                let local = target.home == hub.node.device.id
                reply = local
                    ? try await within(seconds: Double(ImpCore.troupeLimits().asyncTimeoutSecs)) { try await self.deliver(text, to: wanted, from: id, among: targets) }
                    : try await deliver(text, to: wanted, from: id, among: targets)
            } catch {
                (reply, failed) = (error.localizedDescription, true)
            }
            if let left = unanswered[id] { unanswered[id] = left > 1 ? left - 1 : nil }
            let event = ImpCore.troupeAnswerEvent(from: wanted, task: task, sent: sent, text: reply, failed: failed)
            wake(id, with: event, shown: reply, from: from, depth: depth + 1)
        }
        return ImpCore.troupeReceipt(to: wanted, task: task)
    }

    /// Gives `id` a turn for an answer that came in. Gone, moved away or asleep: nobody to tell, it is dropped.
    private func wake(_ id: UUID, with event: String, shown: String, from: ChatTurn.Sender, depth: Int) {
        guard store.contains(id), hub.node.holder(of: id) == nil, hasBrain(id) else { return }
        enqueue(id) { [self] in _ = try? await answer(shown, of: id, answered: (event, from), depth: depth) }
    }

    /// The result of `work`, or a failure once `seconds` pass (then `work` is cancelled).
    private func within(seconds: Double, _ work: @escaping @MainActor () async throws -> String) async throws -> String {
        final class Once { var done = false }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let finish: @MainActor (Result<String, Error>) -> Void = { result in
                guard !once.done else { return }
                once.done = true
                continuation.resume(with: result)
            }
            let job = Task { @MainActor in
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                job.cancel()
                finish(.failure(Failure(String(localized: "No answer came in time."))))
            }
        }
    }

    /// Another pocket Imp's answer, once it has got round to it.
    private func asked(_ other: PocketImp, _ text: String, from sender: ChatTurn.Sender) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let queued = enqueue(other.id, abort: {
                continuation.resume(throwing: Failure(String(localized: "\(other.name) isn't around")))
            }) { [self] in
                // Another Imp of this iPhone asks: it is the owner's own, so tools are allowed.
                let (reply, failed) = await respond(to: text, of: other.id, from: sender, limitedTo: nil)
                continuation.resume(with: failed ? .failure(Failure(reply)) : .success(reply))
            }
            if !queued { continuation.resume(throwing: Failure(String(localized: "\(other.name) is busy"))) }
        }
    }

    /// One question from another Imp, here: it shows on the stage while the Imp thinks, and so does
    /// the answer (or why there is none). The text goes straight back to the asker. Only the
    /// bubble waits for a voice (see `StageVoice`).
    /// `turnID`: the question's id when it came from another device, so the asker's copy and this one are one exchange (`AskedTalks`).
    private func respond(to text: String, of id: UUID, from sender: ChatTurn.Sender, limitedTo device: String?, turnID: UUID? = nil) async -> (reply: String, failed: Bool) {
        guard let imp = store.imp(id) else { return (String(localized: "That Imp isn't on this iPhone."), true) }
        let said = say(.asked, to: sender.name, hue: sender.hue, text, for: id)
        var reply = ""
        var failed = false
        do {
            guard hasBrain(id) else { throw Failure(String(localized: "\(imp.name) has no brain yet.")) }
            let answer = try await answer(text, of: id, from: sender, limitedTo: device, turnID: turnID)
            (reply, failed) = (answer.turn.reply, answer.turn.failed)
        } catch is CancellationError {
            (reply, failed) = (String(localized: "Stopped."), true)
        } catch {
            (reply, failed) = (error.localizedDescription, true)
        }
        // Deleted or taken in meanwhile: nobody is left to say it.
        if store.contains(id) {
            unsay(said, for: id)
            say(.reply, to: sender.name, hue: sender.hue, text, answer: reply, for: id)
        }
        return (reply, failed)
    }

    /// The answer of an Imp on another device, or why there isn't one. The node fails a question
    /// nobody answers in time, and one whose device went away.
    private func askAway(_ target: LinkStaged, _ text: String, from imp: LinkImp, id message: UUID) async throws -> String {
        let unreachable = Failure(String(localized: "\(target.imp.name) isn't around"))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let holder = hub.node.holder(of: imp.id) ?? hub.node.device.id
                switch hub.node.talk(id: message, from: imp, to: target.id, toHome: target.home, text: text, holder: holder) {
                case .via: pending[message] = continuation
                case .here, .unreachable: continuation.resume(throwing: unreachable)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(message, .failure(CancellationError())) }
        }
    }

    private func finish(_ message: UUID, _ result: Result<String, Error>) {
        pending.removeValue(forKey: message)?.resume(with: result)
    }

    // MARK: Hearing other devices

    private func heard(_ event: PocketEvent) {
        switch event {
        case .adopted(let id):
            forget(id)
            hub.refresh()
            onEvent?(.left(id))
        case .answer(let id, let text, let failed):
            finish(id, failed ? .failure(Failure(text, isAnswer: true)) : .success(text))
        case .notAdopted(let id, let device, let sure):
            settle(id, by: device, sure: sure)
        case .connected:
            break
        case .trust(let device):
            for imp in store.imps where hub.node.holder(of: imp.id) == device { tellBrain(imp.id) }
        case .stage(let device):
            decide(movesTo: device)
        case .lost(let device):
            // No way to hear from it any more: whatever it hasn't confirmed is still ours.
            for (id, mac) in moving where mac == device {
                moving[id] = nil
                onEvent?(.refused(id, String(localized: "\(hub.deviceName(device)) didn't take it")))
            }
            onEvent?(.roster)
        case .asked(let id, let from, let to, let text, let by, let trusted):
            let gone = LinkMessage.answer(id: id, text: String(localized: "That Imp isn't on this iPhone."), failed: true)
            guard store.contains(to), !isMoving(to) else {
                hub.node.send(gone, to: by)
                return
            }
            let queued = enqueue(to, from: by, abort: { [self] in hub.node.send(gone, to: by) }) { [self] in
                let (reply, failed) = await respond(to: text, of: to, from: ChatTurn.Sender(id: from.id, name: from.name, hue: from.hue),
                                                    limitedTo: trusted ? nil : hub.deviceName(by), turnID: id)
                hub.node.send(.answer(id: id, text: reply, failed: failed), to: by)
            }
            if !queued {
                let name = store.imp(to)?.name ?? String(localized: "That Imp")
                hub.node.send(.answer(id: id, text: String(localized: "\(name) is busy. Try again in a moment."), failed: true), to: by)
            }
        case .claimed(let id):
            pushAll(id)
        case .ask(let id, let text, let trusted):
            let holder = hub.node.holder(of: id)
            ask(id, text, from: holder, limitedTo: trusted ? nil : holder.map(hub.deviceName) ?? String(localized: "another device"))
        case .stop(let id):
            stop(id)
        case .newChat(let id):
            newChat(id)
        case .felt(let id, let feeling):
            let step: AnticStep = switch feeling {
            case .poke: AnticStep(duration: 0.7, mood: .surprised, glyph: .exclaim)
            case .cuddle: AnticStep(duration: 1.2, mood: .happy, glyph: .heart)
            case .shake: AnticStep(duration: 1.6, mood: .dizzy)
            case .drop: AnticStep(duration: 0.9, mood: .surprised, glyph: .sweat)
            }
            tell(id, .animate(imp: id, beats: [AnimationBeat(step)]))
        case .file(let transfer, _, let from):
            // A pocket Imp has no folder: what its replies show is on the web, which the holder loads itself.
            hub.node.send(.fileFailed(id: transfer, reason: String(localized: "That file isn't on this iPhone.")), to: from)
        case .talks(let id, let from):
            let lines = talkLines.filter { $0.asker.id == id || $0.answerer.id == id }
            hub.node.send(.talkLines(imp: id, lines: TalkLog.forLink(lines)), to: from)
        }
    }

    // MARK: Telling the holder

    /// Tells the device that holds `id` (if another does) something about it.
    private func tell(_ id: UUID, _ message: LinkMessage) {
        if let holder = hub.node.holder(of: id) { hub.node.send(message, to: holder) }
    }

    private func pushChat(_ id: UUID) { tell(id, .chat(imp: id, turns: Array(turns(id).suffix(200)))) }

    private func pushWork(_ id: UUID) {
        tell(id, .work(imp: id, work: work[id]))
        tell(id, .mood(imp: id, mood: (mood(id) ?? .idle).rawValue))
    }

    /// Whether it has a brain to think with: without one it sleeps on the holder too.
    private func tellBrain(_ id: UUID) {
        guard store.contains(id) else { return }
        tell(id, .brain(imp: id, ready: hasBrain(id), tools: hub.node.holder(of: id).map(hub.isTrusted) ?? true))
    }

    /// A new holder hears how the Imp looks, whether it can think and what it's doing.
    private func pushAll(_ id: UUID) {
        guard let look = store.imp(id)?.look else { return }
        tell(id, .look(imp: look))
        tellBrain(id)
        pushChat(id)
        pushWork(id)
        tell(id, .speech(imp: id, speech: speeches[id]))
    }

    // MARK: On the stage

    /// Puts a bubble above `id`'s head. Returns its id, to take it away again.
    @discardableResult
    private func say(_ role: LinkSpeech.Role, to peer: String, hue: Double, _ question: String, answer: String = "", for id: UUID) -> UUID {
        let speech = LinkSpeech(id: UUID(), role: role, peer: peer, hue: hue, question: question, text: answer)
        if let old = speeches[id] { dismiss(old, for: id) }
        speeches[id] = speech
        tell(id, .speech(imp: id, speech: speech))
        guard role == .reply else { return speech.id }
        // Voices in the reply take their turns. The bubble stays up while they do (web ones only:
        // a pocket Imp has no folder on the Mac).
        StageVoice.shared.expect(speech) { LinkFiles.isWeb($0) }
        speechClear[id] = Task { [weak self] in
            try? await StageVoice.shared.linger(over: speech)
            guard !Task.isCancelled, let self, speeches[id]?.id == speech.id else { return }
            dismiss(speech, for: id)
        }
        return speech.id
    }

    /// Takes away the bubble `speech` if it's still the one showing (its answer came in).
    private func unsay(_ speech: UUID, for id: UUID) {
        guard let shown = speeches[id], shown.id == speech else { return }
        dismiss(shown, for: id)
    }

    /// Hides an Imp's bubble (tapped away).
    func dismissSpeech(_ id: UUID) {
        if let speech = speeches[id] { dismiss(speech, for: id) }
    }

    private func dismiss(_ speech: LinkSpeech, for id: UUID) {
        speechClear[id]?.cancel()
        speechClear[id] = nil
        speeches[id] = nil
        tell(id, .speech(imp: id, speech: nil))
        StageVoice.shared.drop(owner: speech.id.uuidString)
    }
}

// MARK: - Chatting

extension PocketRuntime: ChatSource {
    var restingStatus: String { String(localized: "Ready") }
    /// A pocket Imp thinks here, for its owner: it always has its tools in its own chat.
    func toolsWithheld(_ id: UUID) -> (title: String, text: String)? { nil }
    func imp(_ id: UUID) -> LinkImp? { store.imp(id)?.look }
    func turns(_ id: UUID) -> [LinkTurn] { store.imp(id)?.turns() ?? [] }
    func working(_ id: UUID) -> LinkWork? { work[id] }
    func act(_ id: UUID) -> Performance? { acts[id] }
    func mood(_ id: UUID) -> Mood? { work[id].map { $0.status == nil ? .thinking : .working } }
    func availability(_ id: UUID) -> ChatAvailability { ChatAvailability(.atHome(brainReady: hasBrain(id))) }

    func peers(_ id: UUID) -> [LinkImp] {
        var seen: Set<String> = [store.imp(id)?.name.lowercased() ?? ""]
        let me = hub.node.device.id
        return targets(of: id, here: looks.map { LinkStaged(imp: $0, home: me) }).map(\.imp)
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    func intro(_ imp: LinkImp, _ availability: ChatAvailability) -> (title: String, text: String) {
        availability == .noBrain
            ? (String(localized: "No brain yet"), String(localized: "\(imp.name) sleeps until it has a service to think with."))
            : (String(localized: "Ask \(imp.name) anything"), String(localized: "It thinks right here on your iPhone, with its tools, and can message your other Imps too."))
    }

    func newChatNote(_ imp: LinkImp) -> String {
        String(localized: "\(imp.name) starts fresh and won't remember this chat.")
    }

    func ask(_ id: UUID, _ text: String) { ask(id, text, from: nil, limitedTo: nil) }

    /// `device`: another device asking (its share of the queue is capped). A full queue drops the ask.
    private func ask(_ id: UUID, _ text: String, from device: UUID?, limitedTo stranger: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasBrain(id) else { return }
        enqueue(id, from: device) { [self] in _ = try? await answer(text, of: id, limitedTo: stranger) }
    }

    func stop(_ id: UUID) { running[id]?.cancel() }

    func newChat(_ id: UUID) {
        store.update(id) { $0.newChat() }
        pushChat(id)
    }
}
