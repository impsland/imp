import Foundation
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
        init(_ text: String) { errorDescription = text }
    }

    /// Something an Imp has to do, after what it's doing now. `abort` says so if the Imp goes before its turn.
    private struct Job {
        var run: @MainActor () async -> Void
        var abort: @MainActor () -> Void
    }

    private static let animations = Reaction.allCases.filter { !$0.unlocksWithFavoriteColor }.map(\.rawValue)

    private let store: PocketStore
    private(set) var work: [UUID: LinkWork] = [:]
    /// What each pocket Imp is saying to another Imp (a bubble above it on the stage), like the
    /// visiting Imps' in `LinkHub.speeches`.
    private(set) var speeches: [UUID: LinkSpeech] = [:]

    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored private let hub: LinkHub
    @ObservationIgnored private let brain: PocketBrain
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [UUID: [Job]] = [:]
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private var speechClear: [UUID: Task<Void, Never>] = [:]

    init(hub: LinkHub, store: PocketStore = PocketStore()) {
        self.hub = hub
        self.store = store
        brain = PocketBrain(secrets: store.secrets)
        hub.onPocket = { [weak self] in self?.heard($0) }
    }

    // MARK: The Imps

    var imps: [PocketImp] { store.imps }
    var looks: [LinkImp] { store.imps.map(\.look) }
    var secrets: any PocketSecrets { store.secrets }

    func contains(_ id: UUID) -> Bool { store.contains(id) }

    /// What the Imps hatched here said to each other (and were asked by Mac Imps), from their chats.
    var talkLines: [TalkLine] {
        store.imps.flatMap { imp in
            TalkLog.lines(answeredBy: ChatTurn.Sender(id: imp.id, name: imp.name, hue: imp.hue), in: imp.chats)
        }
    }

    /// A linked Mac's name on the network (`.local` first): where a model server on the Mac is
    /// reached from this phone. Nil when no Mac is linked.
    var macHost: String? { hub.macHost }

    func hasBrain(_ id: UUID) -> Bool {
        store.imp(id).map { (try? $0.validate()) != nil } ?? false
    }

    func hatch(_ imp: PocketImp) {
        store.add(imp)
    }

    func edit(_ id: UUID, _ change: (inout PocketImp) -> Void) {
        store.update(id, change)
        if let look = store.imp(id)?.look { tell(id, .look(imp: look)) }
    }

    /// Deletes an Imp. If another device holds it, it is called home first so that device lets go.
    func delete(_ id: UUID) {
        hub.node.callHome(id)
        hub.refresh()
        forget(id)
    }

    /// The Imp is gone (deleted, or taken in by a Mac): what it was doing stops, what waited for it
    /// is told it isn't around, and nothing of it stays on the stage.
    private func forget(_ id: UUID) {
        store.remove(id)
        let dropped = waiting.removeValue(forKey: id) ?? []
        running[id]?.cancel()
        work[id] = nil
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
        guard running[id] == nil else {
            onEvent?(.refused(id, String(localized: "\(imp.name) is busy thinking. Move it once it's done.")))
            return
        }
        do {
            let (kit, secrets) = try imp.adoption(secrets: store.secrets)
            let entry = LinkEntry.after(exit: exit.side, height: exit.height, speed: exit.speed)
            guard hub.node.adopt(id, kit: kit, secrets: secrets, entry: entry, to: device) != nil else {
                throw Failure(String(localized: "\(hub.deviceName(device)) isn't around"))
            }
        } catch {
            onEvent?(.refused(id, error.localizedDescription))
        }
    }

    // MARK: Asking

    /// Runs `job` after what the Imp is already doing.
    private func enqueue(_ id: UUID, abort: @escaping @MainActor () -> Void = {}, _ run: @escaping @MainActor () async -> Void) {
        waiting[id, default: []].append(Job(run: run, abort: abort))
        if running[id] == nil { next(id) }
    }

    private func next(_ id: UUID) {
        guard !(waiting[id] ?? []).isEmpty else {
            running[id] = nil
            waiting[id] = nil
            return
        }
        let job = waiting[id]!.removeFirst()
        running[id] = Task { await job.run(); next(id) }
    }

    /// One ask, from you or from another Imp: thinks, files the turn in its chat.
    private func answer(_ text: String, of id: UUID, from sender: ChatTurn.Sender? = nil) async throws -> PocketAnswer {
        guard let imp = store.imp(id) else { throw Failure(String(localized: "That Imp isn't on this iPhone.")) }
        let result = try await brain.ask(text, of: imp, from: sender, talk: talk(for: imp)) { [weak self] work in
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

    private func talk(for imp: PocketImp) -> PocketTalk {
        let id = imp.id
        let me = hub.node.device.id
        let here = store.imps.filter { hasBrain($0.id) }.map { LinkStaged(imp: $0.look, home: me) }
        var taken = Set([imp.name.lowercased()])
        let named = targets(of: id, here: here).filter { taken.insert($0.imp.name.lowercased()).inserted }
        return PocketTalk(others: named.map(\.imp.name), send: { [weak self] to, text in
            guard let self else { throw CancellationError() }
            return try await self.deliver(text, to: to, from: id, among: named)
        }, animations: Self.animations, play: { [weak self] names in
            await self?.play(names, for: id)
        })
    }

    /// The Imps `id` can message: those of this iPhone and the ones on the screen its body is on.
    private func targets(of id: UUID, here: [LinkStaged]) -> [LinkStaged] {
        let stage = hub.node.holder(of: id).map { hub.node.stage(of: $0) } ?? hub.staged
        return LinkTalks.targets(of: id, mine: here, stage: stage)
    }

    private func deliver(_ text: String, to name: String, from id: UUID, among targets: [LinkStaged]) async throws -> String {
        guard let sender = store.imp(id), let target = targets.first(where: { $0.imp.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Failure(String(localized: "\(name) isn't around"))
        }
        let asking = say(.asking, to: target.imp.name, hue: target.imp.hue, text, for: id)
        defer { unsay(asking, for: id) }
        if let other = store.imp(target.id), target.home == hub.node.device.id {
            return try await asked(other, text, from: ChatTurn.Sender(id: sender.id, name: sender.name, hue: sender.hue))
        }
        return try await askAway(target, text, from: sender.look)
    }

    /// Another pocket Imp's answer, once it has got round to it.
    private func asked(_ other: PocketImp, _ text: String, from sender: ChatTurn.Sender) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(other.id, abort: {
                continuation.resume(throwing: Failure(String(localized: "\(other.name) isn't around")))
            }) { [self] in
                let (reply, failed) = await respond(to: text, of: other.id, from: sender)
                continuation.resume(with: failed ? .failure(Failure(reply)) : .success(reply))
            }
        }
    }

    /// One question from another Imp, here: it shows on the stage while the Imp thinks, and so does
    /// the answer (or why there is none). The text goes straight back to the asker; only the
    /// bubble waits for a voice (see `StageVoice`).
    private func respond(to text: String, of id: UUID, from sender: ChatTurn.Sender) async -> (reply: String, failed: Bool) {
        guard let imp = store.imp(id) else { return (String(localized: "That Imp isn't on this iPhone."), true) }
        let said = say(.asked, to: sender.name, hue: sender.hue, text, for: id)
        var reply = ""
        var failed = false
        do {
            guard hasBrain(id) else { throw Failure(String(localized: "\(imp.name) has no brain yet.")) }
            let answer = try await answer(text, of: id, from: sender)
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
    private func askAway(_ target: LinkStaged, _ text: String, from imp: LinkImp) async throws -> String {
        let message = UUID()
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

    private func play(_ names: [String], for id: UUID) {
        let beats = names.compactMap(Reaction.init(rawValue:)).flatMap { Antics.steps(for: $0, work: .zero).map(AnimationBeat.init) }
        if !beats.isEmpty { onEvent?(.animate(id, beats)) }
    }

    // MARK: Hearing other devices

    private func heard(_ event: PocketEvent) {
        switch event {
        case .adopted(let id):
            forget(id)
            hub.refresh()
            onEvent?(.left(id))
        case .answer(let id, let text, let failed):
            finish(id, failed ? .failure(Failure(text)) : .success(text))
        case .asked(let id, let from, let to, let text, let by):
            let gone = LinkMessage.answer(id: id, text: String(localized: "That Imp isn't on this iPhone."), failed: true)
            guard store.contains(to) else {
                hub.node.send(gone, to: by)
                return
            }
            enqueue(to, abort: { [self] in hub.node.send(gone, to: by) }) { [self] in
                let (reply, failed) = await respond(to: text, of: to, from: ChatTurn.Sender(id: from.id, name: from.name, hue: from.hue))
                hub.node.send(.answer(id: id, text: reply, failed: failed), to: by)
            }
        case .claimed(let id):
            pushAll(id)
        case .ask(let id, let text):
            ask(id, text)
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

    /// A new holder hears how the Imp looks and what it's doing.
    private func pushAll(_ id: UUID) {
        guard let look = store.imp(id)?.look else { return }
        tell(id, .look(imp: look))
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
        // Voices in the reply take their turns; the bubble stays up while they do (web ones only:
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
    var restingStatus: String { String(localized: "Lives on this iPhone") }
    func imp(_ id: UUID) -> LinkImp? { store.imp(id)?.look }
    func turns(_ id: UUID) -> [LinkTurn] { store.imp(id)?.turns() ?? [] }
    func working(_ id: UUID) -> LinkWork? { work[id] }
    func mood(_ id: UUID) -> Mood? { work[id].map { $0.status == nil ? .thinking : .working } }
    func availability(_ id: UUID) -> ChatAvailability { hasBrain(id) ? .ready : .noBrain }

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

    func ask(_ id: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasBrain(id) else { return }
        enqueue(id) { [self] in _ = try? await answer(text, of: id) }
    }

    func stop(_ id: UUID) { running[id]?.cancel() }

    func newChat(_ id: UUID) {
        store.update(id) { $0.newChat() }
        pushChat(id)
    }
}
