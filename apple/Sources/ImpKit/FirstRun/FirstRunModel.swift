import Foundation
import ImpCore
import Observation

/// The Brain the user chose, as the path checks it and then hands it over.
public struct FirstRunBrain: Equatable, Sendable {
    public var name: String
    public var baseURL: String
    public var model: String
    /// Empty for a model server on a computer. The path never logs it and keeps it only until it is handed over.
    public var key: String
    public var isLocal: Bool

    public init(name: String, baseURL: String, model: String, key: String, isLocal: Bool) {
        self.name = name; self.baseURL = baseURL; self.model = model; self.key = key; self.isLocal = isLocal
    }
}

/// What the path needs from outside: the network and nothing else.
public struct FirstRunServices: Sendable {
    /// The model servers on this computer.
    public var find: @Sendable () async -> [LocalServer]
    /// The models a service lists, with its key.
    public var models: @Sendable (_ baseURL: String, _ key: String) async throws -> [String]
    /// A tiny request: it works, or it throws what went wrong.
    public var check: @Sendable (_ brain: FirstRunBrain) async throws -> Void

    public init(find: @escaping @Sendable () async -> [LocalServer],
                models: @escaping @Sendable (String, String) async throws -> [String],
                check: @escaping @Sendable (FirstRunBrain) async throws -> Void) {
        self.find = find; self.models = models; self.check = check
    }

    /// The real requests. `persona` is what the Imp is told before the tiny request.
    public static func live(persona: String, probeSeconds: Double, listSeconds: Double, checkSeconds: Double,
                            session: URLSession = .shared) -> FirstRunServices {
        let finder = LocalServerFinder(timeout: probeSeconds)
        return FirstRunServices(
            find: { await finder.find() },
            models: { try await OpenAIClient(baseURL: $0, apiKey: $1, session: session).models(timeout: listSeconds) },
            check: { brain in
                let client = try OpenAIClient(baseURL: brain.baseURL, apiKey: brain.key, session: session)
                _ = try await withTimeout(seconds: checkSeconds) {
                    try await client.chat(model: brain.model, messages: [.system(persona), .user("Say hi to me in one short sentence.")]).text
                }
            })
    }

    /// Runs `work`, or throws `APIError.timedOut` when it takes longer than `seconds`.
    static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw APIError.timedOut(seconds: Int(seconds))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw APIError.timedOut(seconds: Int(seconds)) }
            return first
        }
    }
}

/// The label and action of the flow's one primary button, for every platform.
public enum FirstRunPrimary: Equatable, Sendable {
    /// "Continue" on step 1.
    case continueToModel
    /// Step 1 is loading the models.
    case loading
    /// "Wake {name} up" on step 2.
    case wake
    /// "Try again" on step 2 after a failure.
    case tryAgain
    /// The Imp is stirring or just woke.
    case waking
    case none
}

/// The first run, step by step. The same on every platform: the views only show it. It holds what the
/// user typed, so going back or a failed check keeps it, and it never blocks anything:
/// closing leaves an existing Imp asleep and a new one unhatched.
@MainActor @Observable
public final class FirstRunModel {
    public let impName: String
    /// Whose Brain this is: an existing Imp's, or a new Imp that is hatched only when the Brain works.
    public let target: FirstRunTarget
    /// Whether local presets are found by looking at this computer (the Mac), or are on another computer whose
    /// address the user edits (the iPhone).
    public let onThisComputer: Bool
    /// The choices: Remote and Local (`ServicePreset.all`).
    public let presets: [ServicePreset]
    /// Whether listing the models fills the model with the first that chats (the Mac's list) or leaves it as it
    /// is (the iPhone's picker, where blank means "picked for you" and the pick is made only when it wakes).
    public let preselectsModel: Bool

    public private(set) var path = FirstRunPath()
    public private(set) var problem: FirstRunProblem?
    /// Looking for model servers on this computer.
    public private(set) var searching = false
    public private(set) var found: [LocalServer] = []
    /// The models the service listed.
    public internal(set) var models: [String] = []

    /// The picked choice: Remote until the user picks Local (`ServicePreset.standard`).
    public private(set) var choice: ServicePreset?
    /// The service address: filled by the choice, always editable.
    public var address = ""
    public var key = ""
    public var model = ""

    @ObservationIgnored private let network: FirstRunServices
    @ObservationIgnored private let adopt: @MainActor (FirstRunBrain, FirstRunTarget) throws -> Void
    @ObservationIgnored private let awakeBeat: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The address and key the models were listed for.
    @ObservationIgnored private var listedFor: String?
    /// The address and key a listing failed for, until a listing works or is asked for again.
    @ObservationIgnored private var listFailedFor: String?
    /// "Wake up" on one page: the models are being listed, and the check follows by itself.
    @ObservationIgnored private var wakesAfterLoading = false

    /// `adopt` keeps the Brain once it works, for `target`: the platform stores the service, the model and the key,
    /// and hatches the Imp when the target is a new one. It throws `KeyNotSaved` when the key could not be
    /// stored, and then nothing is kept.
    /// `found` are the model servers already known (a later `discover()` replaces them).
    /// `awakeBeat` is how long the awake Imp is shown before the flow moves on by itself.
    public init(impName: String, target: FirstRunTarget, onThisComputer: Bool, services: FirstRunServices,
                presets: [ServicePreset] = ServicePreset.all, awakeBeat: Duration = .milliseconds(900),
                preselectsModel: Bool = true, found: [LocalServer] = [],
                adopt: @escaping @MainActor (FirstRunBrain, FirstRunTarget) throws -> Void) {
        self.impName = impName
        self.target = target
        self.onThisComputer = onThisComputer
        self.presets = presets
        self.preselectsModel = preselectsModel
        self.network = services
        self.awakeBeat = awakeBeat
        self.adopt = adopt
        self.found = found
        if let first = presets.first(where: { $0 == ServicePreset.standard }) ?? presets.first { choose(first) }
    }

    // MARK: Step 1: the service

    /// Picks Remote or Local: it fills its address (still editable, on another device, a local one names the
    /// computer to edit).
    public func choose(_ picked: ServicePreset) {
        problem = nil
        choice = picked
        address = onThisComputer || !picked.isLocal ? picked.baseURL : picked.baseURL(onHost: ServicePreset.exampleHost)
    }

    /// The picked choice.
    public var preset: ServicePreset? { choice }

    /// Whether the service runs on the user's own computer: Local, or an address of one.
    public var isLocalService: Bool { preset?.isLocal == true || ServicePreset.isOwnComputer(address) }

    /// Local needs no key, so the field is not shown.
    public var showsKey: Bool { preset?.isLocal != true }

    /// Remote insists on a key while its address is the preset's own service: an edited address may be open.
    public var keyIsRequired: Bool { preset.map { !$0.isLocal && ServicePreset.matching(address) == $0 } ?? false }

    /// On another device a local preset's address is the computer's: the user edits the host.
    public var needsHost: Bool { !onThisComputer && preset?.isLocal == true }

    /// The model server running on this computer for `preset`, when the Mac found one.
    public func running(_ preset: ServicePreset) -> LocalServer? {
        guard preset.isLocal else { return nil }
        return found.first { ServicePreset.matching($0.baseURL) == preset }
    }

    /// Looks for model servers on this computer (the Mac). Local is marked as found when its server answers.
    /// Nothing is picked for the user: Remote stays the choice until they pick Local.
    public func discover() {
        guard onThisComputer else { return }
        searching = true
        Task { [network] in
            found = await network.find()
            searching = false
        }
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why step 1 cannot go on yet, or nil when it can.
    public var missing: FirstRunProblem? {
        if !ServicePreset.isValidAddress(address) { return .badAddress }
        if keyIsRequired, trimmedKey.isEmpty { return .emptyKey }
        return nil
    }

    // MARK: Moving

    /// Whether the step indicator may jump to step `n`. Never past what is unmet: the models must be listed for the
    /// address and key as they are now.
    public func canGo(to n: Int) -> Bool {
        path.canGo(to: n) && (n < 2 || modelsAreCurrent)
    }

    /// Jumps to step `n` (1 or 2) when `canGo(to:)`. Typed values stay.
    public func go(to n: Int) {
        guard canGo(to: n) else { return }
        task?.cancel()
        problem = nil
        path.go(to: n)
    }

    /// One step back. Running work stops. Typed values stay.
    public func back() {
        guard path.canGoBack else { return }
        task?.cancel()
        wakesAfterLoading = false
        problem = nil
        path.apply(.back)
    }

    /// The sheet or page was closed: a listing or check still running stops, so a Brain is not adopted for an Imp
    /// the user left asleep.
    public func cancel() {
        task?.cancel()
    }

    /// What the one primary button does at this moment.
    public var primary: FirstRunPrimary {
        switch path.step {
        case .service: .continueToModel
        case .loadingModels: .loading
        case .model: .wake
        case .failed: .tryAgain
        case .checking, .awake: .waking
        case .done: .none
        }
    }

    // MARK: Step 1 -> 2: the models

    private var modelsAreCurrent: Bool { listedFor == listKey }
    /// The address and key the last listing failed for: a typed model is tried without listing them again.
    private var listingFailed: Bool { listFailedFor == listKey }
    private var listKey: String { trimmedAddress + "\n" + trimmedKey }

    /// Continue on step 1: loads the models from the address with the key. A failure keeps what was typed.
    public func continueFromService() {
        if let missing {
            problem = missing
            return
        }
        problem = nil
        if listingFailed, path.step == .service, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            path.apply(.skipList)
            return
        }
        if modelsAreCurrent, path.step == .service {
            path.go(to: 2)
            return
        }
        task?.cancel()
        path.apply(.load)
        guard path.step == .loadingModels else { return }
        let base = trimmedAddress, typed = trimmedKey, listing = listKey, local = isLocalService
        task = Task { [network] in
            do {
                let names = try await network.models(base, typed)
                guard !Task.isCancelled else { return }
                models = names
                listedFor = listing
                listFailedFor = nil
                if preselectsModel, model.isEmpty || (!names.isEmpty && !names.contains(model)) { model = Self.suggested(from: names) }
                path.apply(.loaded)
                if wakesAfterLoading {
                    wakesAfterLoading = false
                    // Left blank: the first model that chats, picked now that the list is here.
                    if model.trimmingCharacters(in: .whitespaces).isEmpty { model = Self.suggested(from: names) }
                    check()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                wakesAfterLoading = false
                listFailedFor = listing
                problem = FirstRunProblem.from(error, local: local)
                path.apply(.loadFailed)
            }
        }
    }

    /// Lists the service's models from wherever the path is, for a single page where the address, the key and
    /// the model are edited together: it rewinds to the service first, so an edited address or key is listed
    /// again. Models already listed for what is typed are kept. Nothing is checked.
    public func listModels() {
        guard !path.isBusy, !path.isOver else { return }
        if modelsAreCurrent, !models.isEmpty { return }
        wakesAfterLoading = false
        // An explicit request lists again, even when the last listing failed.
        listFailedFor = nil
        rewindToService()
        continueFromService()
    }

    /// Back to the service step, whatever step the path is on.
    private func rewindToService() {
        while path.step != .service {
            let before = path.step
            path.apply(.back)
            if path.step == before { return }
        }
    }

    /// The whole first run in one press, for a single page with the address, the key and the model: lists the
    /// models when they are not listed yet (a blank model becomes the first one that chats), then checks.
    /// A failure says what to do and keeps what was typed. The same call is "Try again".
    public func wakeUp() {
        if let missing {
            problem = missing
            return
        }
        guard !path.isBusy, !path.isOver else { return }
        if path.step != .service, modelsAreCurrent, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            check()
            return
        }
        // The listing failed, and a model was typed: try that model, do not list again first.
        if path.step == .service, listingFailed, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            path.apply(.skipList)
            check()
            return
        }
        rewindToService()
        guard path.step == .service else { return }
        wakesAfterLoading = true
        continueFromService()
        if path.step == .model {
            wakesAfterLoading = false
            if model.trimmingCharacters(in: .whitespaces).isEmpty { model = Self.suggested(from: models) }
            check()
        } else if path.step != .loadingModels {
            wakesAfterLoading = false
        }
    }

    /// The model to preselect: the first one that chats (not an embedding, speech or image model).
    public static func suggested(from names: [String]) -> String {
        let other = ["embed", "whisper", "tts", "moderation", "rerank", "dall-e"]
        return names.first { name in !other.contains { name.lowercased().contains($0) } } ?? names.first ?? ""
    }

    /// The models that match what is typed in the model field.
    public var matchingModels: [String] {
        let typed = model.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty, !models.contains(model) else { return models }
        return models.filter { $0.lowercased().contains(typed) }
    }

    /// The listed models for a search field that is separate from the choice: the chosen model first, so
    /// it is always in view, then the ones that contain what was typed. An empty search lists them all.
    public func models(matching query: String) -> [String] {
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = typed.isEmpty ? models : models.filter { $0.lowercased().contains(typed) }
        guard typed.isEmpty, let at = found.firstIndex(of: model) else { return found }
        return [model] + found[..<at] + found[(at + 1)...]
    }

    // MARK: Step 2: the check

    /// The service the sentences name.
    public var serviceName: String { URL(string: trimmedAddress)?.host ?? trimmedAddress }

    /// The sentence for the problem, or nil when there is none.
    public var problemText: String? {
        problem?.sentence(service: serviceName, model: model)
    }

    /// What the user chose so far, or why it cannot be checked yet.
    func brain() -> (FirstRunBrain?, FirstRunProblem?) {
        if let missing { return (nil, missing) }
        let picked = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return (nil, .noModel) }
        let typed = showsKey ? trimmedKey : ""
        return (FirstRunBrain(name: serviceName, baseURL: trimmedAddress, model: picked, key: typed, isLocal: isLocalService), nil)
    }

    /// Whether "check" has what it needs.
    public var canCheck: Bool { brain().0 != nil }

    /// Tries a tiny request. It wakes the Imp when it works, hands the Brain over and ends the flow by itself.
    /// It says what to do when it does not, and the same call is "Try again".
    public func check() {
        guard path.step == .model || path.step == .failed else { return }
        let (chosen, missing) = brain()
        guard let chosen else {
            problem = missing
            return
        }
        task?.cancel()
        problem = nil
        path.apply(.check)
        let beat = awakeBeat
        task = Task { [network, adopt, target] in
            do {
                try await network.check(chosen)
                guard !Task.isCancelled else { return }
                try adopt(chosen, target)
                path.apply(.checkWorked)
                try await Task.sleep(for: beat)
                path.apply(.carryOn)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                problem = FirstRunProblem.from(error, local: chosen.isLocal)
                path.apply(.checkFailed)
            }
        }
    }
}
