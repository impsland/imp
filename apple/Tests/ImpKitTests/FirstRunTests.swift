import Foundation
import Testing
@testable import ImpKit

@Suite struct FirstRunPathTests {
    private func path(_ events: FirstRunEvent...) -> FirstRunPath {
        var p = FirstRunPath()
        events.forEach { p.apply($0) }
        return p
    }

    @Test func theHappyPathGoesThroughTwoSteps() {
        var p = FirstRunPath()
        #expect(p.step == .service && p.number == 1 && p.reached == 1)
        let steps: [(FirstRunEvent, FirstRunStep, Int?)] = [
            (.load, .loadingModels, 1), (.loaded, .model, 2), (.check, .checking, 2), (.checkWorked, .awake, 2),
            (.carryOn, .done, nil),
        ]
        for (event, step, number) in steps {
            p.apply(event)
            #expect(p.step == step && p.number == number, "\(event)")
        }
        #expect(p.isOver)
    }

    @Test func aFailedLoadStaysOnTheServiceStep() {
        #expect(path(.load, .loadFailed).step == .service)
        #expect(path(.load, .loadFailed).reached == 1)
    }

    @Test func aFailedCheckStaysOnStepTwoAndTriesAgainFromThere() {
        let failed = path(.load, .loaded, .check, .checkFailed)
        #expect(failed.step == .failed && failed.number == 2)
        var again = failed
        again.apply(.check)
        #expect(again.step == .checking)
        again.apply(.checkWorked)
        #expect(again.step == .awake)
    }

    @Test func backStepsOneAtATimeAndIsNotOnTheFirstStep() {
        #expect(!path().canGoBack)
        #expect(path(.back).step == .service)
        #expect(path(.load, .loaded, .back).step == .service)
        #expect(path(.load, .back).step == .service)
        #expect(path(.load, .loaded, .check, .back).step == .model)
        #expect(path(.load, .loaded, .check, .checkFailed, .back).step == .model)
        #expect(path(.load, .loaded, .check, .checkWorked, .carryOn, .back).step == .done)
        #expect(!path(.load, .loaded, .check, .checkWorked).canGoBack)
    }

    @Test func theIndicatorJumpsOnlyToStepsAlreadyReached() {
        var p = path()
        #expect(!p.canGo(to: 2) && !p.canGo(to: 1))
        p.apply(.load); p.apply(.loaded)
        #expect(p.canGo(to: 1) && !p.canGo(to: 2) && !p.canGo(to: 3))
        p.go(to: 3)
        #expect(p.step == .model)
        p.go(to: 1)
        #expect(p.step == .service && p.reached == 2)
        #expect(p.canGo(to: 2) && !p.canGo(to: 0) && !p.canGo(to: 3))
        p.go(to: 2)
        #expect(p.step == .model)
    }

    @Test func nothingJumpsWhileSomethingRunsOrAfterTheEnd() {
        #expect(!path(.load).canGo(to: 1))
        let checking = path(.load, .loaded, .check)
        #expect(checking.isBusy && !checking.canGo(to: 1))
        #expect(path(.load, .loaded, .check, .checkWorked).isBusy)
        var done = path(.load, .loaded, .check, .checkWorked, .carryOn)
        done.go(to: 1)
        #expect(done.step == .done && !done.canGo(to: 1))
    }

    @Test func noStateOffersToSkip() {
        // The only ways out of the first step are Continue and Close, and every named step is reachable only by its work.
        #expect(path(.carryOn, .checkWorked, .check).step == .service)
        #expect(FirstRunPath.names == ["firstrun.step.service", "firstrun.step.model"] && FirstRunPath.totalSteps == 2)
        #expect(!String(describing: FirstRunEvent.back).contains("later"))
    }

    @Test func anEventThatMakesNoSenseChangesNothing() {
        #expect(path(.checkWorked, .carryOn, .loaded).step == .service)
        #expect(path(.load, .check).step == .loadingModels)
    }

    @Test func theImpIsAsleepUntilTheCheckWorks() {
        var p = FirstRunPath()
        var seen: [FirstRunImpState] = [p.imp]
        for event in [FirstRunEvent.load, .loaded, .check, .checkWorked, .carryOn] { p.apply(event); seen.append(p.imp) }
        #expect(seen == [.asleep, .asleep, .asleep, .stirring, .awake, .awake])
        #expect(path(.load, .loaded, .check, .checkFailed).imp == .asleep)
    }
}

@Suite struct FirstRunPreferencesTests {
    @Test func theFirstRunIsRememberedAndSurvivesSaving() throws {
        var prefs = ImpPreferences()
        #expect(!prefs.firstRunSeen)
        prefs.firstRunSeen = true
        let again = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(again.firstRunSeen)
    }

    @Test func aBrainIsKeptAsTheDefaultAndNeverTakesTheKeyAlong() throws {
        var prefs = ImpPreferences()
        let imp = prefs.imps[0].id
        let brain = FirstRunBrain(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "some/model", key: "fake-key", isLocal: false)
        let id = prefs.adopt(brain, for: imp)
        #expect(prefs.ai.services.map(\.baseURL) == [brain.baseURL])
        #expect(prefs.ai.brain.service == id && prefs.ai.model() == "some/model" && prefs.imps[0].brain == nil)
        let stored = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self)
        #expect(!stored.contains("fake-key"))
    }

    @Test func theSameAddressIsReusedNotAddedTwice() {
        var prefs = ImpPreferences()
        let imp = prefs.imps[0].id
        var brain = FirstRunBrain(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "a", key: "", isLocal: true)
        let first = prefs.adopt(brain, for: imp)
        brain.model = "b"
        #expect(prefs.adopt(brain, for: imp) == first)
        #expect(prefs.ai.services.count == 1 && prefs.ai.model() == "b")
    }
}

@Suite struct FirstRunProblemTests {
    @Test func errorsBecomeProblemsAndKeys() {
        let cases: [(Error, Bool, FirstRunProblem, String)] = [
            (APIError.http(status: 401, message: "x"), false, .wrongKey, "error.brain.key"),
            (APIError.http(status: 403, message: "x"), false, .wrongKey, "error.brain.key"),
            (APIError.missingKey, false, .wrongKey, "error.brain.key"),
            (APIError.http(status: 404, message: "x"), false, .modelMissing, "error.brain.model"),
            (APIError.http(status: 404, message: "x"), true, .modelMissing, "error.brain.model"),
            (APIError.timedOut(seconds: 20), false, .timeout, "error.brain.timeout"),
            (URLError(.timedOut), false, .timeout, "error.brain.timeout"),
            (URLError(.notConnectedToInternet), false, .noNetwork, "error.brain.offline"),
            (URLError(.cannotConnectToHost), true, .noServer, "error.brain.local"),
            (URLError(.cannotConnectToHost), false, .unreachable, "error.brain.unreachable"),
            (URLError(.cannotFindHost), false, .unreachable, "error.brain.unreachable"),
            (APIError.noModel, false, .noModel, "firstrun.error.no_model"),
            (APIError.http(status: 500, message: "x"), false, .generic, "error.generic"),
            (APIError.emptyResponse("text"), false, .generic, "error.generic"),
            (CocoaError(.fileReadUnknown), true, .noServer, "error.brain.local"),
        ]
        for (error, local, problem, key) in cases {
            let got = FirstRunProblem.from(error, local: local)
            #expect(got == problem, "\(error) local \(local)")
            #expect(got.key == key)
        }
    }

    @Test func anEmptyKeyHasItsOwnSentence() {
        #expect(FirstRunProblem.emptyKey.key == "firstrun.error.empty_key")
        #expect(FirstRunProblem.badAddress.key == "firstrun.error.address")
    }
}

@Suite struct LocalServerFinderTests {
    private func models(_ names: String...) -> Data {
        Data(("{\"data\":[" + names.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",") + "]}").utf8)
    }

    @Test func serversAreFoundInTheCoresOrderWhoeverAnswersFirst() async {
        let finder = LocalServerFinder(host: "localhost", timeout: 2) { url, _ in
            switch url.port {
            case 8080: return Data("{\"data\":[{\"id\":\"b\"}]}".utf8)
            case 11434:
                try await Task.sleep(for: .milliseconds(80))
                return Data("{\"data\":[{\"id\":\"z\"},{\"id\":\"a\"}]}".utf8)
            default: throw URLError(.cannotConnectToHost)
            }
        }
        let found = await finder.find()
        #expect(found.map(\.name) == ["Ollama", "llama.cpp"])
        #expect(found.first?.baseURL == "http://localhost:11434/v1")
        #expect(found.first?.models == ["a", "z"])
    }

    @Test func aServerWithNoModelsOrNoAnswerIsLeftOut() async {
        let finder = LocalServerFinder(timeout: 2) { url, _ in
            switch url.port {
            case 11434: return Data("{\"data\":[]}".utf8)
            case 1234: return Data("not json".utf8)
            default: throw URLError(.timedOut)
            }
        }
        #expect(await finder.find().isEmpty)
    }

    @Test func everyProbeGetsTheShortTimeoutAndAsksForTheModelList() async {
        let seen = Seen()
        let finder = LocalServerFinder(host: "my-mac.local", timeout: 1.5) { url, timeout in
            await seen.add("\(url.absoluteString) \(timeout)")
            throw URLError(.timedOut)
        }
        _ = await finder.find()
        let all = await seen.all.sorted()
        #expect(all == ["http://my-mac.local:11434/v1/models 1.5", "http://my-mac.local:1234/v1/models 1.5", "http://my-mac.local:8080/v1/models 1.5"].sorted())
    }
}

private actor Seen {
    var all: [String] = []
    func add(_ text: String) { all.append(text) }
}

@MainActor @Suite struct FirstRunModelTests {
    private let server = LocalServer(name: "Ollama", baseURL: "http://localhost:11434/v1", models: ["llama3", "qwen3"])

    private func make(mac: Bool = true, found: [LocalServer] = [], models: [String] = ["m1", "m2"],
                      check: @escaping @Sendable (FirstRunBrain) async throws -> Void = { _ in },
                      adopted: Adopted = Adopted(),
                      keep: @escaping @MainActor (FirstRunBrain) throws -> Void = { _ in }) -> FirstRunModel {
        let services = FirstRunServices(find: { found }, models: { _, _ in models }, check: check)
        return FirstRunModel(impName: "Imp", onThisComputer: mac, services: services, awakeBeat: .zero) { adopted.brains.append($0); try keep($0) }
    }

    private func settle(_ model: FirstRunModel, until done: @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private var remote: ServicePreset { ServicePreset.all[0] }
    private var local: ServicePreset { ServicePreset.all[1] }

    /// To the model step with a key typed on Remote.
    private func atModels(_ model: FirstRunModel) async {
        model.choose(remote)
        model.key = "fake-key"
        model.continueFromService()
        await settle(model) { model.path.step == .model }
    }

    @Test func remoteIsTheDefaultAndAChoiceFillsTheAddressTheUserMayEdit() {
        let model = make()
        #expect(remote.isLocal == false && local.isLocal && ServicePreset.standard == remote)
        #expect(model.choice == remote && model.address == remote.baseURL && remote.baseURL.contains("openrouter.ai"))
        model.address = "https://proxy.example.com/v1"
        #expect(model.choice == remote && model.address == "https://proxy.example.com/v1")
        model.choose(local)
        #expect(model.address == local.baseURL && local.baseURL.contains(":11434"))
        model.choose(remote)
        #expect(model.address == remote.baseURL)
    }

    @Test func localNeedsNoKeyAndRemoteDoes() {
        let model = make()
        model.choose(local)
        #expect(!model.showsKey && !model.keyIsRequired && model.missing == nil)
        model.choose(remote)
        #expect(model.showsKey && model.keyIsRequired && model.missing == .emptyKey)
        model.key = "fake-key"
        #expect(model.missing == nil)
    }

    @Test func anEditedRemoteAddressIsAcceptedWithoutAKey() async {
        let model = make()
        model.address = ""
        model.continueFromService()
        #expect(model.problem == .badAddress && model.path.step == .service)
        model.address = "not a url"
        model.continueFromService()
        #expect(model.problem == .badAddress)
        model.address = " https://llm.example.com/v1 "
        #expect(model.missing == nil && model.showsKey && !model.keyIsRequired)
        model.continueFromService()
        await settle(model) { model.path.step == .model }
        #expect(model.path.step == .model && model.problem == nil)
        model.check()
        await settle(model) { model.path.step == .done }
        #expect(model.path.step == .done)
    }

    @Test func theMacMarksARunningLocalServerButKeepsRemote() async {
        let model = make(found: [server])
        model.discover()
        await settle(model) { !model.searching }
        #expect(model.running(local) == server && model.running(remote) == nil)
        #expect(model.choice == remote && model.address == remote.baseURL, "Remote stays the default")
    }

    @Test func aFoundServerDoesNotOverrideWhatTheUserPicked() async {
        let model = make(found: [server])
        model.choose(local)
        model.discover()
        await settle(model) { !model.searching }
        #expect(model.choice == local && model.running(local) == server)
    }

    @Test func withNothingFoundRemoteStaysAndIsEditable() async {
        let model = make()
        model.discover()
        await settle(model) { !model.searching }
        #expect(model.choice == remote && model.found.isEmpty)
    }

    @Test func thePhoneGetsBothChoicesAndEditsTheHostOfLocal() {
        let model = make(mac: false)
        #expect(model.presets == ServicePreset.all)
        model.choose(local)
        #expect(model.needsHost && model.address == "http://\(ServicePreset.exampleHost):11434/v1")
        model.address = "http://192.168.1.20:11434/v1"
        #expect(model.missing == nil)
        model.discover()
        #expect(model.found.isEmpty && !model.searching)
    }

    @Test func continueLoadsTheModelsAndPreselectsOne() async {
        let model = make(models: ["text-embedding-3", "gpt-chat", "other"])
        #expect(model.primary == .continueToModel)
        await atModels(model)
        #expect(model.models == ["text-embedding-3", "gpt-chat", "other"] && model.model == "gpt-chat")
        #expect(model.primary == .wake && model.canCheck && model.path.reached == 2)
    }

    @Test func continueWithoutAKeyOnACloudPresetFailsInPlace() {
        let model = make()
        model.continueFromService()
        #expect(model.problem == .emptyKey && model.path.step == .service)
    }

    @Test func wakingUpOnOnePageListsTheModelsPicksOneAndChecks() async {
        let adopted = Adopted()
        let model = make(models: ["text-embedding-3", "m2"], adopted: adopted)
        model.key = "fake-key"
        model.wakeUp()
        await settle(model) { model.path.step == .done }
        #expect(model.path.step == .done)
        #expect(adopted.brains.map(\.model) == ["m2"])
    }

    @Test func listingTheModelsOnOnePageWorksFromAnyStepAndChecksNothing() async {
        let adopted = Adopted()
        let model = make(models: ["m1", "m2"], adopted: adopted)
        model.key = "fake-key"
        model.listModels()
        await settle(model) { model.path.step == .model }
        #expect(model.models == ["m1", "m2"] && model.model == "m1" && adopted.brains.isEmpty)
        // An edited address is listed again, from the model step.
        model.address = "https://llm.example.com/v1"
        model.listModels()
        #expect(model.path.step == .loadingModels)
        await settle(model) { model.path.step == .model }
        #expect(model.path.step == .model && adopted.brains.isEmpty)
    }

    @Test func withoutPreselectingTheModelStaysBlankUntilItWakes() async {
        let adopted = Adopted()
        let services = FirstRunServices(find: { [] }, models: { _, _ in ["text-embedding-3", "chat-1", "chat-2"] }, check: { _ in })
        let model = FirstRunModel(impName: "Imp", onThisComputer: false, services: services, awakeBeat: .zero,
                                  preselectsModel: false) { adopted.brains.append($0) }
        model.key = "fake-key"
        model.listModels()
        await settle(model) { model.path.step == .model }
        #expect(model.model.isEmpty && model.models.count == 3, "listing leaves the choice to the person")
        model.model = "my-own-model"
        model.listModels()
        #expect(model.model == "my-own-model", "a typed name that is not listed is kept")
        model.model = ""
        model.wakeUp()
        await settle(model) { model.path.step == .done }
        #expect(adopted.brains.map(\.model) == ["chat-1"], "blank wakes with the first model that chats")
    }

    @Test func wakingUpWithoutAKeyOnlyNamesTheProblem() {
        let model = make()
        model.wakeUp()
        #expect(model.problem == .emptyKey && model.path.step == .service)
    }

    @Test func aFailedModelListKeepsWhatWasTyped() async {
        let services = FirstRunServices(find: { [] }, models: { _, _ in throw APIError.http(status: 401, message: "no") }, check: { _ in })
        let model = FirstRunModel(impName: "Imp", onThisComputer: true, services: services) { _ in }
        model.key = "fake-key"
        model.continueFromService()
        await settle(model) { model.problem != nil }
        #expect(model.path.step == .service && model.problem == .wrongKey && model.key == "fake-key" && model.address == ServicePreset.all[0].baseURL)
    }

    @Test func aTypedModelIsTriedWhenTheServiceGivesNoList() async {
        let adopted = Adopted()
        let services = FirstRunServices(find: { [] },
                                        models: { _, _ in throw APIError.http(status: 404, message: "no list") },
                                        check: { _ in })
        let model = FirstRunModel(impName: "Imp", onThisComputer: true, services: services, awakeBeat: .zero) { adopted.brains.append($0) }
        model.address = "http://127.0.0.1:9/v1"
        model.continueFromService()
        await settle(model) { model.problem != nil }
        #expect(model.path.step == .service && model.problem == .modelMissing)
        // The person types the model the server does not list. Waking tries it, without listing again.
        model.model = "my-local-model"
        model.wakeUp()
        await settle(model) { model.path.step == .done }
        #expect(adopted.brains.map(\.model) == ["my-local-model"])
    }

    @Test func aWorkingCheckWakesTheImpHandsOverTheBrainAndEndsByItself() async {
        let adopted = Adopted()
        let model = make(adopted: adopted)
        await atModels(model)
        model.model = " m2 "
        model.check()
        #expect(model.path.step == .checking && model.path.imp == .stirring)
        await settle(model) { model.path.step == .done }
        #expect(model.path.step == .done && model.path.imp == .awake && model.primary == .none)
        #expect(adopted.brains == [FirstRunBrain(name: "openrouter.ai", baseURL: ServicePreset.all[0].baseURL, model: "m2", key: "fake-key", isLocal: false)])
    }

    @Test func aLocalBrainIsHandedOverWithoutAKey() async {
        let adopted = Adopted()
        let model = make(found: [server], models: ["llama3"], adopted: adopted)
        model.discover()
        await settle(model) { !model.searching }
        model.choose(local)
        model.key = "ignored"
        model.continueFromService()
        await settle(model) { model.path.step == .model }
        model.check()
        await settle(model) { model.path.step == .done }
        #expect(adopted.brains == [FirstRunBrain(name: "localhost", baseURL: server.baseURL, model: "llama3", key: "", isLocal: true)])
    }

    @Test func noModelMeansNoRequest() async {
        let adopted = Adopted()
        let model = make(models: [], adopted: adopted)
        await atModels(model)
        #expect(model.model == "" && !model.canCheck)
        model.check()
        #expect(model.problem == .noModel && model.path.step == .model && adopted.brains.isEmpty)
        model.model = "typed/by-hand"
        #expect(model.canCheck)
    }

    @Test func aRefusedKeyFailsWithAWordedSentenceAndTriesAgainOnTheSameStep() async {
        let adopted = Adopted()
        let tries = Count()
        let model = make(check: { _ in
            if await tries.next() == 1 { throw APIError.http(status: 401, message: "no") }
        }, adopted: adopted)
        await atModels(model)
        model.model = "some/model"
        model.check()
        await settle(model) { model.path.step == .failed }
        #expect(model.path.step == .failed && model.problem == .wrongKey && adopted.brains.isEmpty)
        #expect(model.problemText?.isEmpty == false && model.primary == .tryAgain)
        #expect(model.key == "fake-key" && model.model == "some/model")
        model.check()
        await settle(model) { model.path.step == .done }
        #expect(model.path.step == .done && model.problem == nil && adopted.brains.count == 1)
    }

    @Test func aKeyThatCannotBeSavedFailsInPlainWordsAndKeepsWhatWasTyped() async {
        let model = make(keep: { _ in throw KeyNotSaved() })
        await atModels(model)
        model.check()
        await settle(model) { model.path.step == .failed }
        #expect(model.problem == .keyNotSaved && model.problem?.key == "firstrun.error.key_not_saved")
        #expect(model.key == "fake-key" && model.model == "m1")
    }

    @Test func theKeyNeverAppearsInAProblemSentence() async {
        let model = make(check: { _ in throw URLError(.notConnectedToInternet) })
        await atModels(model)
        model.key = "fake-secret-value"
        model.check()
        await settle(model) { model.path.step == .failed }
        #expect(model.problem == .noNetwork)
        #expect(model.problemText?.contains("fake-secret-value") == false)
    }

    @Test func typedValuesSurviveMovingBetweenSteps() async {
        let model = make()
        await atModels(model)
        model.model = "m2"
        model.address = model.address + ""
        model.back()
        #expect(model.path.step == .service && model.key == "fake-key" && model.model == "m2" && model.address == ServicePreset.all[0].baseURL)
        // The models are still the ones listed for this address and key: the indicator may jump forward.
        #expect(model.canGo(to: 2))
        model.go(to: 2)
        #expect(model.path.step == .model && model.model == "m2")
    }

    @Test func theIndicatorNeverJumpsPastUnmetRequirements() async {
        let model = make()
        #expect(!model.canGo(to: 2) && !model.canGo(to: 3))
        await atModels(model)
        model.back()
        model.key = "another-key"
        #expect(!model.canGo(to: 2))
        model.go(to: 2)
        #expect(model.path.step == .service)
        model.continueFromService()
        await settle(model) { model.path.step == .model }
        #expect(model.path.step == .model)
    }

    @Test func thereIsNoBackOnTheFirstStepEvenWhileLoading() async {
        let model = make()
        model.key = "fake-key"
        model.continueFromService()
        #expect(model.path.step == .loadingModels && !model.path.canGoBack)
        model.back()
        #expect(model.path.step == .loadingModels && model.key == "fake-key")
        await settle(model) { model.path.step == .model }
        #expect(model.path.step == .model)
    }

    @Test func theMatchingModelsFollowWhatIsTyped() async {
        let model = make(models: ["alpha/one", "alpha/two", "beta"])
        await atModels(model)
        model.model = "alpha/one"
        #expect(model.matchingModels.count == 3)
        model.model = "TWO"
        #expect(model.matchingModels == ["alpha/two"])
    }
}

private actor Count {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

@MainActor final class Adopted {
    var brains: [FirstRunBrain] = []
}

@Suite struct FirstRunPocketTests {
    @Test func aCheckedServiceBecomesTheImpsBrainWithoutItsKey() {
        let brain = FirstRunBrain(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "some/model", key: "fake-key", isLocal: false)
        let service = PocketService(brain)
        #expect(service == PocketService(baseURL: "https://openrouter.ai/api/v1", model: "some/model", name: "OpenRouter"))
        #expect(!String(describing: service).contains("fake-key"))
    }

    @Test func aServerOnTheNetworkIsKeptByItsAddress() {
        let brain = FirstRunBrain(name: "192.168.1.20", baseURL: "http://192.168.1.20:11434/v1", model: "llama3", key: "", isLocal: true)
        #expect(PocketService(brain).baseURL == "http://192.168.1.20:11434/v1")
        #expect(PocketService(brain).isEmpty == false)
    }
}
