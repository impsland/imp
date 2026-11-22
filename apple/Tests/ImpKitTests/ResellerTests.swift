import Foundation
import ImpCore
import Testing
@testable import ImpKit

/// What the build says it comes with, the key issuer against a scripted network, and the out-of-credit answer.
/// The English words of a key, from the String Catalog (a test bundle has no compiled strings).
func english(_ key: String) throws -> String {
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Localization/Localizable.xcstrings")
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: [String: Any]])
    let localizations = try #require(strings[key]?["localizations"] as? [String: [String: [String: String]]])
    return try #require(localizations["en"]?["stringUnit"]?["value"])
}

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/reseller/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// A network that answers from a script, in order, and remembers what it was asked.
final class ScriptedNetwork: @unchecked Sendable {
    enum Answer { case reply(IssuerResponse), fail(URLError.Code) }
    private let lock = NSLock()
    private var script: [Answer]
    private(set) var requests: [IssuerRequest] = []

    init(_ script: [Answer]) { self.script = script }

    func append(_ more: [Answer]) { lock.withLock { script += more } }

    var http: @Sendable (IssuerRequest) async throws -> IssuerResponse {
        { [self] request in
            let answer: Answer = lock.withLock {
                requests.append(request)
                return script.isEmpty ? .fail(.notConnectedToInternet) : script.removeFirst()
            }
            switch answer {
            case .reply(let response): return response
            case .fail(let code): throw URLError(code)
            }
        }
    }
}

let notRequired = ScriptedNetwork.Answer.reply(IssuerResponse(status: 200, body: #"{"required":false}"#))
let issuedKey = ScriptedNetwork.Answer.reply(IssuerResponse(status: 200, body: #"{"key":"sk-res-abc"}"#))
func modelList() throws -> ScriptedNetwork.Answer { .reply(IssuerResponse(status: 200, body: try fixture("models.json"))) }

@Suite struct ResellerBuildTests {
    private let base = "https://models.example.com/v1"
    private let issuance = "https://models.example.com/v1/signup"

    @Test func emptyMeansAManualBuild() {
        #expect(ResellerBuild.settings(base: "", issuance: "") == nil)
        #expect(ResellerBuild.settings(base: nil, issuance: nil) == nil)
    }

    @Test func bothSetMeansAnAutomaticBuild() throws {
        let settings = try #require(ResellerBuild.settings(base: base, issuance: issuance))
        #expect(settings.host == "models.example.com" && settings.baseUrl == base && settings.issuanceUrl == issuance)
    }

    @Test func invalidOrHalfSetMeansAManualBuild() {
        #expect(ResellerBuild.settings(base: base, issuance: "") == nil)
        #expect(ResellerBuild.settings(base: nil, issuance: issuance) == nil)
        #expect(ResellerBuild.settings(base: "not an address", issuance: issuance) == nil)
    }

    @Test func aBundleWithoutTheKeysIsAManualBuild() {
        #expect(ResellerBuild.settings(in: Bundle(for: ScriptedNetwork.self)) == nil)
    }
}

@MainActor @Suite struct KeyIssuerTests {
    private let settings = ResellerSettings(baseUrl: "https://models.example.com/v1", issuanceUrl: "https://models.example.com/v1/signup", host: "models.example.com")

    private final class Shelf { var kept: [FirstRunBrain] = []; var now = Date(timeIntervalSince1970: 1000) }

    private func issuer(_ network: ScriptedNetwork, _ shelf: Shelf, existing: FirstRunBrain? = nil) -> KeyIssuer {
        KeyIssuer(settings: settings, http: network.http, existing: { existing }, store: { shelf.kept.append($0) }, now: { shelf.now })
    }

    @Test func successStoresTheKeyAndPresetsTheService() async throws {
        let network = ScriptedNetwork([notRequired, issuedKey, try modelList()])
        let shelf = Shelf()
        let issuer = issuer(network, shelf)
        #expect(issuer.state == .idle)
        issuer.start()
        #expect(issuer.state == .issuing)
        await issuer.settled()
        #expect(issuer.state == .issued)
        let kept = try #require(shelf.kept.first)
        #expect(shelf.kept.count == 1 && kept.key == "sk-res-abc" && kept.baseURL == settings.baseUrl && kept.name == "models.example.com" && kept.model == "assistant")
        #expect(network.requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(network.requests[2].url == settings.baseUrl + "/models" && network.requests[2].bearer == "sk-res-abc")
        #expect(network.requests[1].bearer == nil)
    }

    @Test func aNetworkErrorCanBeTriedAgain() async {
        let issuer = issuer(ScriptedNetwork([.fail(.notConnectedToInternet)]), Shelf())
        issuer.start()
        await issuer.settled()
        #expect(issuer.state == .failed(retryable: true, wait: nil))
        #expect(issuer.canRetry)
    }

    @Test func aServerErrorCanBeTriedAgain() async {
        let issuer = issuer(ScriptedNetwork([.reply(IssuerResponse(status: 503, body: ""))]), Shelf())
        issuer.start()
        await issuer.settled()
        #expect(issuer.state == .failed(retryable: true, wait: nil))
    }

    @Test func tooManyRequestsWaitsForRetryAfter() async throws {
        let rate = IssuerResponse(status: 429, body: try fixture("error-429-rate.json"), retryAfter: "30")
        let network = ScriptedNetwork([notRequired, .reply(rate)])
        let shelf = Shelf()
        let issuer = issuer(network, shelf)
        issuer.start()
        await issuer.settled()
        #expect(issuer.state == .failed(retryable: true, wait: 30))
        #expect(issuer.detail?.isEmpty == false)
        shelf.now = shelf.now.addingTimeInterval(10)
        issuer.retry()
        #expect(!issuer.canRetry && issuer.state == .failed(retryable: true, wait: 30))
        #expect(network.requests.count == 2)
        network.append([notRequired, issuedKey, try modelList()])
        shelf.now = shelf.now.addingTimeInterval(21)
        #expect(issuer.canRetry)
        issuer.retry()
        await issuer.settled()
        #expect(issuer.state == .issued)
    }

    @Test func retryAsksForAFreshChallenge() async throws {
        let network = ScriptedNetwork([.fail(.timedOut), notRequired, issuedKey, try modelList()])
        let issuer = issuer(network, Shelf())
        issuer.start()
        await issuer.settled()
        issuer.retry()
        await issuer.settled()
        #expect(issuer.state == .issued)
        let challenges = network.requests.filter { $0.method == "GET" && $0.url.contains("challenge") }
        #expect(challenges.count == 2)
    }

    @Test func aKeyThatCouldNotBeUsedIsNotIssuedTwice() async throws {
        let network = ScriptedNetwork([notRequired, issuedKey, .reply(IssuerResponse(status: 500, body: "")), try modelList()])
        let shelf = Shelf()
        let issuer = issuer(network, shelf)
        issuer.start()
        await issuer.settled()
        issuer.retry()
        await issuer.settled()
        #expect(issuer.state == .issued)
        #expect(network.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test func oneIssuancePerInstall() async throws {
        let network = ScriptedNetwork([notRequired, issuedKey, try modelList()])
        let issuer = issuer(network, Shelf())
        issuer.start()
        await issuer.settled()
        issuer.start()
        issuer.retry()
        await issuer.settled()
        #expect(network.requests.count == 3)
        let known = FirstRunBrain(name: "models.example.com", baseURL: settings.baseUrl, model: "assistant", key: "", isLocal: false)
        let later = ScriptedNetwork([])
        let again = self.issuer(later, Shelf(), existing: known)
        again.start()
        #expect(again.state == .issued && again.brain == known && later.requests.isEmpty)
    }
}

@Suite struct OutOfCreditTests {
    private func answer(_ status: Int, _ body: String) throws {
        let response = HTTPURLResponse(url: URL(string: "https://models.example.com/v1/chat/completions")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        try OpenAIClient.check(response, data: Data(body.utf8))
    }

    @Test func anEmptyBalanceSaysSoWithTheServicesOwnWords() throws {
        let error = #expect(throws: APIError.self) { try answer(429, try fixture("error-429-quota.json")) }
        guard case .outOfCredit(let message) = error else { Issue.record("not out of credit: \(String(describing: error))"); return }
        #expect(message.contains("Top up at"))
        #expect(error?.errorDescription != APIError.http(status: 429, message: "").errorDescription)
    }

    @Test func theOutOfCreditWordsCarryTheServicesMessage() throws {
        let template = try english("api.out_of_credit")
        #expect(String(format: template, "Top up at https://api.example.com/workspace/.").contains("Top up at"))
    }

    @Test func aRateLimitStaysTooManyRequests() throws {
        let error = #expect(throws: APIError.self) { try answer(429, try fixture("error-429-rate.json")) }
        guard case .http(let status, _) = error else { Issue.record("not a plain 429: \(String(describing: error))"); return }
        #expect(status == 429)
    }
}
