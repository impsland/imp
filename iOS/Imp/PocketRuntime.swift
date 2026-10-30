import Foundation
import ImpKit
import Observation

/// The Imps hatched on this iPhone, alive: each thinks here, with its own service and tools, one ask
/// at a time. They message each other directly, and the Imps on the Mac through the link. Moving one
/// to the Mac is a toss the Mac has to confirm.
@MainActor @Observable
final class PocketRuntime {
    private struct Failure: LocalizedError, Sendable {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private typealias Job = @MainActor () async -> Void

    /// How long a pocket Imp waits for a Mac Imp's answer.
    private static let answerTimeout: TimeInterval = 120
    private static let animations = Reaction.allCases.filter { !$0.unlocksWithFavoriteColor }.map(\.rawValue)

    private let store: PocketStore
    private(set) var work: [UUID: LinkWork] = [:]

    @ObservationIgnored var onEvent: ((StageEvent) -> Void)?
    @ObservationIgnored private let client: LinkClient
    @ObservationIgnored private let brain: PocketBrain
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [UUID: [Job]] = [:]
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<String, Error>] = [:]

    init(client: LinkClient, store: PocketStore = PocketStore()) {
        self.client = client
        self.store = store
        brain = PocketBrain(secrets: store.secrets)
        client.onPocket = { [weak self] in self?.heard($0) }
        client.setTroupe(looks)
    }

    // MARK: The Imps

    var imps: [PocketImp] { store.imps }
    var looks: [LinkImp] { store.imps.map(\.look) }
    var secrets: any PocketSecrets { store.secrets }

    func contains(_ id: UUID) -> Bool { store.contains(id) }

    func hasBrain(_ id: UUID) -> Bool {
        store.imp(id).map { (try? $0.validate()) != nil } ?? false
    }

    func hatch(_ imp: PocketImp) {
        store.add(imp)
        client.setTroupe(looks)
    }

    func edit(_ id: UUID, _ change: (inout PocketImp) -> Void) {
        store.update(id, change)
        client.setTroupe(looks)
    }

    func delete(_ id: UUID) {
        forget(id)
        client.setTroupe(looks)
    }

    private func forget(_ id: UUID) {
        running[id]?.cancel()
        waiting[id] = nil
        work[id] = nil
        store.remove(id)
    }

    // MARK: Moving home

    /// Throws `id` to the Mac. It stays here until the Mac says it has it (`PocketEvent.adopted`).
    func toss(_ id: UUID, exit: LinkSide, height: Double, speed: Double) {
        guard let imp = store.imp(id) else { return }
        do {
            let request = try imp.adoption(secrets: store.secrets, exit: exit, height: height, speed: speed)
            guard client.send(request) else { throw Failure(String(localized: "Your Mac isn't around")) }
        } catch {
            onEvent?(.refused(id, error.localizedDescription))
        }
    }

    // MARK: Asking

    /// Runs `job` after what the Imp is already doing.
    private func enqueue(_ id: UUID, _ job: @escaping Job) {
        waiting[id, default: []].append(job)
        if running[id] == nil { next(id) }
    }

    private func next(_ id: UUID) {
        guard !(waiting[id] ?? []).isEmpty else {
            running[id] = nil
            waiting[id] = nil
            return
        }
        let job = waiting[id]!.removeFirst()
        running[id] = Task { await job(); next(id) }
    }

    /// One ask, from you or from another Imp: thinks, files the turn in its chat.
    private func answer(_ text: String, of id: UUID, from sender: ChatTurn.Sender? = nil) async throws -> PocketAnswer {
        guard let imp = store.imp(id) else { throw Failure(String(localized: "That Imp isn't on this iPhone.")) }
        let result = try await brain.ask(text, of: imp, from: sender, talk: talk(for: imp)) { [weak self] work in
            await self?.report(work, for: id)
        }
        store.update(id) { $0.record(result) }
        return result
    }

    private func report(_ work: LinkWork?, for id: UUID) { self.work[id] = work }

    // MARK: Messaging

    private func talk(for imp: PocketImp) -> PocketTalk {
        let id = imp.id
        let here = store.imps.filter { $0.id != id && hasBrain($0.id) }.map(\.name)
        var taken = Set(here.map { $0.lowercased() })
        taken.insert(imp.name.lowercased())
        let macs = macImps.map(\.name).filter { taken.insert($0.lowercased()).inserted }
        return PocketTalk(others: here + macs, send: { [weak self] to, text in
            guard let self else { throw CancellationError() }
            return try await self.deliver(text, to: to, from: id)
        }, animations: Self.animations, play: { [weak self] names in
            await self?.play(names, for: id)
        })
    }

    /// The Imps on the Mac, when it's there.
    private var macImps: [LinkImp] { client.isConnected ? client.imps + client.others : [] }

    private func deliver(_ text: String, to name: String, from id: UUID) async throws -> String {
        guard let sender = store.imp(id).map({ ChatTurn.Sender(id: $0.id, name: $0.name, hue: $0.hue) }) else { throw CancellationError() }
        if let other = store.imps.first(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return try await asked(other, text, from: sender)
        }
        if let mac = macImps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return try await askMac(mac, text, from: id)
        }
        throw Failure(String(localized: "\(name) isn't around"))
    }

    /// Another pocket Imp's answer, once it has got round to it.
    private func asked(_ other: PocketImp, _ text: String, from sender: ChatTurn.Sender) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(other.id) { [self] in
                guard hasBrain(other.id) else {
                    return continuation.resume(throwing: Failure(String(localized: "\(other.name) has no brain yet.")))
                }
                do {
                    let answer = try await answer(text, of: other.id, from: sender)
                    continuation.resume(with: answer.turn.failed ? .failure(Failure(answer.turn.reply)) : .success(answer.turn.reply))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A Mac Imp's answer, or why there isn't one.
    private func askMac(_ mac: LinkImp, _ text: String, from id: UUID) async throws -> String {
        let message = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard client.send(.message(id: message, from: id, to: mac.id, text: text)) else {
                    return continuation.resume(throwing: Failure(String(localized: "Your Mac isn't around")))
                }
                pending[message] = continuation
                Task {
                    try? await Task.sleep(for: .seconds(Self.answerTimeout))
                    finish(message, .failure(Failure(String(localized: "\(mac.name) didn't answer"))))
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

    // MARK: Hearing the Mac

    private func heard(_ event: PocketEvent) {
        switch event {
        case .adopted(let id):
            forget(id)
            client.setTroupe(looks)
            onEvent?(.left(id))
        case .answer(let id, let text, let failed):
            finish(id, failed ? .failure(Failure(text)) : .success(text))
        case .ask(let id, let from, let to, let text):
            enqueue(to) { [self] in await serve(id, from, to, text) }
        case .linkLost:
            for id in pending.keys { finish(id, .failure(Failure(String(localized: "Your Mac isn't around")))) }
        }
    }

    /// A Mac Imp's question for one of ours.
    private func serve(_ id: UUID, _ from: LinkImp, _ to: UUID, _ text: String) async {
        var reply = ""
        var failed = false
        do {
            guard hasBrain(to) else { throw PocketError.noBrain }
            let answer = try await answer(text, of: to, from: ChatTurn.Sender(id: from.id, name: from.name, hue: from.hue))
            (reply, failed) = (answer.turn.reply, answer.turn.failed)
        } catch is CancellationError {
            (reply, failed) = (String(localized: "Stopped."), true)
        } catch {
            (reply, failed) = (error.localizedDescription, true)
        }
        client.send(.answered(id: id, text: reply, failed: failed))
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
        return (looks + macImps).filter { $0.id != id && seen.insert($0.name.lowercased()).inserted }
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

    func newChat(_ id: UUID) { store.update(id) { $0.newChat() } }
}
