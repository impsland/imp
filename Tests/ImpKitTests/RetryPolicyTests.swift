import Foundation
import Testing
@testable import ImpKit

/// Plays queued outcomes for the model: a reply body, an HTTP status, a dropped connection, or a
/// stream that starts and then breaks.
final class OutcomeProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome { case body(String), status(Int), drop, streamThenDrop(String), hang }
    nonisolated(unsafe) static var queue: [Outcome] = []
    nonisolated(unsafe) static var requests = 0
    static let lock = NSLock()

    static func reset(_ outcomes: [Outcome]) { lock.withLock { queue = outcomes; requests = 0 } }
    static var count: Int { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let next: Outcome = Self.lock.withLock {
            Self.requests += 1
            return Self.queue.isEmpty ? .drop : Self.queue.removeFirst()
        }
        func respond(_ status: Int, _ type: String) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        switch next {
        case .body(let body):
            respond(200, "application/json")
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code):
            respond(code, "application/json")
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"nope"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .streamThenDrop(let first):
            respond(200, "text/event-stream")
            client?.urlProtocol(self, didLoad: Data(first.utf8))
            // The break comes a moment later, after the text had time to be read.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .hang:
            break
        }
    }
    override func stopLoading() {}
}

private actor Naps {
    private(set) var waits: [TimeInterval] = []
    func add(_ s: TimeInterval) { waits.append(s) }
}

private actor Notices {
    private(set) var all: [RetryNotice] = []
    func add(_ n: RetryNotice) { all.append(n) }
}

@Suite(.serialized) struct RetryPolicyTests {
    private let policy = RetryPolicy(retries: 3, delay: 1, multiplier: 2)

    // MARK: Classifier

    @Test func retriesPassingFailures() {
        for code in [URLError.Code.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(policy.isRetryable(URLError(code)))
        }
        for status in [408, 429, 500, 502, 503, 529] {
            #expect(policy.isRetryable(APIError.http(status: status, message: "")))
        }
    }

    @Test func neverRetriesAuthenticationOrValidationErrors() {
        for status in [400, 401, 402, 403, 404, 413, 422] {
            #expect(!policy.isRetryable(APIError.http(status: status, message: "")))
        }
        #expect(!policy.isRetryable(APIError.missingKey))
        #expect(!policy.isRetryable(APIError.needsBrain(imp: "Pip")))
        #expect(!policy.isRetryable(APIError.noModel))
        #expect(!policy.isRetryable(APIError.timedOut(seconds: 5)))
        #expect(!policy.isRetryable(URLError(.cancelled)))
        #expect(!policy.isRetryable(URLError(.badURL)))
        #expect(!policy.isRetryable(CancellationError()))
    }

    // MARK: Count and backoff

    @Test func backoffGrowsAndIsCapped() {
        #expect(policy.delay(beforeRetry: 1) == 1)
        #expect(policy.delay(beforeRetry: 2) == 2)
        #expect(policy.delay(beforeRetry: 3) == 4)
        let capped = RetryPolicy(retries: 9, delay: 10, multiplier: 10, maxDelay: 30)
        #expect(capped.delay(beforeRetry: 3) == 30)
    }

    @Test func triesOnceThenRetriesTheSetNumberOfTimes() async {
        let naps = Naps(), notices = Notices()
        let tries = Counter()
        await #expect(throws: URLError.self) {
            try await policy.run(sleep: { await naps.add($0) }, onRetry: { await notices.add($0) }) {
                await tries.bump()
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(await tries.count == 4)
        #expect(await naps.waits == [1, 2, 4])
        #expect(await notices.all.map(\.attempt) == [1, 2, 3])
        #expect(await notices.all.allSatisfy { $0.of == 3 })
        #expect(await notices.all[1].text == String(localized: "Retrying 2 of 3"))
    }

    @Test func stopsRetryingOnceItWorks() async throws {
        let tries = Counter()
        let value = try await policy.run(sleep: { _ in }) {
            await tries.bump()
            if await tries.count < 3 { throw APIError.http(status: 503, message: "busy") }
            return "ok"
        }
        #expect(value == "ok")
        #expect(await tries.count == 3)
    }

    @Test func doesNotRetryAuthenticationErrors() async {
        let tries = Counter()
        await #expect(throws: APIError.http(status: 401, message: "bad key")) {
            try await policy.run(sleep: { _ in }) {
                await tries.bump()
                throw APIError.http(status: 401, message: "bad key")
            }
        }
        #expect(await tries.count == 1)
    }

    @Test func noRetriesMeansOneTry() async {
        let tries = Counter()
        await #expect(throws: URLError.self) {
            try await RetryPolicy.none.run(sleep: { _ in }) { await tries.bump(); throw URLError(.timedOut) }
        }
        #expect(await tries.count == 1)
    }

    @Test func aVetoStopsTheRetry() async {
        let tries = Counter()
        await #expect(throws: URLError.self) {
            try await policy.run(sleep: { _ in }, canRetry: { false }) { await tries.bump(); throw URLError(.timedOut) }
        }
        #expect(await tries.count == 1)
    }

    // MARK: Cancellation

    @Test func cancellingDuringTheWaitStopsAtOnce() async {
        let tries = Counter()
        let task = Task {
            try await policy.run(sleep: { _ in try await Task.sleep(for: .seconds(60)) }) {
                await tries.bump()
                throw URLError(.networkConnectionLost)
            }
        }
        while await tries.count == 0 { await Task.yield() }
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await tries.count == 1)
    }

    @Test func aCancelledTaskNeverStarts() async {
        let tries = Counter()
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            return try await policy.run(sleep: { _ in }) { await tries.bump(); return 1 }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await tries.count == 0)
    }

    // MARK: Deadline

    @Test func aSlowRequestEndsWithAReadableError() async {
        let started = Date()
        do {
            _ = try await RequestDeadline.run(seconds: 0.1) {
                try await Task.sleep(for: .seconds(60))
                return 1
            }
            Issue.record("should have timed out")
        } catch let error as APIError {
            guard case .timedOut = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.localizedDescription.contains("Brain"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aQuickRequestIsLeftAlone() async throws {
        let value = try await RequestDeadline.run(seconds: 30) { 7 }
        #expect(value == 7)
    }

    // MARK: Settings

    @Test func limitsHaveOneSetOfDefaultsAndStaySane() {
        let d = RequestLimits.standard
        #expect(d.timeoutSeconds == 120 && d.retries == 3 && d.retryDelaySeconds == 1 && d.backoff == 2)
        #expect(ImpPreferences().requests == d)
        var wild = RequestLimits()
        wild.timeoutSeconds = -4; wild.retries = 999; wild.retryDelaySeconds = .nan; wild.backoff = 0
        let tame = wild.clamped
        #expect(tame.timeoutSeconds >= 5 && tame.retries == 10 && tame.retryDelaySeconds == d.retryDelaySeconds && tame.backoff == 1)
        var prefs = ImpPreferences()
        prefs.requests.retries = 5
        let back = try? JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back?.requests.retries == 5)
    }

    @Test func theIPhoneReadsTheSameLimits() throws {
        let defaults = try #require(UserDefaults(suiteName: "RetryPolicyTests-\(UUID().uuidString)"))
        #expect(RequestLimits.stored(in: defaults) == .standard)
        defaults.set(2, forKey: RequestLimits.Key.retries)
        defaults.set(30.0, forKey: RequestLimits.Key.timeout)
        let l = RequestLimits.stored(in: defaults)
        #expect(l.retries == 2 && l.timeoutSeconds == 30 && l.backoff == 2)
    }

    // MARK: The agent, end to end

    private func agent(_ outcomes: [OutcomeProtocol.Outcome], limits: RequestLimits = .standard) throws -> Agent {
        OutcomeProtocol.reset(outcomes)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeProtocol.self]
        let client = try OpenAIClient(baseURL: "https://example.test/v1", apiKey: "k", session: URLSession(configuration: config))
        return Agent(client: client, model: "m", limits: limits, sleep: { _ in }, deadlineSleep: { _ in try await Task.sleep(for: .seconds(600)) })
    }
    private let answer = #"{"choices":[{"message":{"content":"done"}}]}"#

    @Test func theAgentRetriesADroppedConnectionAndTellsWhich() async throws {
        let a = try agent([.drop, .drop, .body(answer)])
        let notices = Notices()
        let (reply, _) = try await a.run([.user("hi")]) { event in
            if case .retrying(let n) = event { await notices.add(n) }
        }
        #expect(reply == "done")
        #expect(OutcomeProtocol.count == 3)
        #expect(await notices.all == [RetryNotice(attempt: 1, of: 3, delay: 1), RetryNotice(attempt: 2, of: 3, delay: 2)])
    }

    @Test func theAgentGivesTheFinalErrorAfterTheLastRetry() async throws {
        let a = try agent([.drop, .drop, .drop, .drop, .drop])
        await #expect(throws: URLError.self) { _ = try await a.run([.user("hi")]) }
        #expect(OutcomeProtocol.count == 4)
    }

    @Test func theAgentNeverRetriesABadKey() async throws {
        let a = try agent([.status(401), .body(answer)])
        await #expect(throws: APIError.self) { _ = try await a.run([.user("hi")]) }
        #expect(OutcomeProtocol.count == 1)
    }

    @Test func theAgentRetriesABusyServiceOnTheStreamToo() async throws {
        let a = try agent([.status(503), .body(answer)])
        let (reply, _) = try await a.run([.user("hi")], stream: true)
        #expect(reply == "done")
        #expect(OutcomeProtocol.count == 2)
    }

    @Test func aStreamThatAlreadyShowedTextIsNotRetried() async throws {
        let chunk = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"# + "\n\n"
        let a = try agent([.streamThenDrop(chunk), .body(answer)])
        let heard = Notices()
        await #expect(throws: URLError.self) {
            _ = try await a.run([.user("hi")], stream: true) { event in
                if case .retrying(let n) = event { await heard.add(n) }
            }
        }
        #expect(OutcomeProtocol.count == 1)
        #expect(await heard.all.isEmpty)
    }

    @Test func aRequestThatNeverAnswersEndsWithinTheSetTime() async throws {
        var limits = RequestLimits()
        limits.timeoutSeconds = 5
        OutcomeProtocol.reset([.hang])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeProtocol.self]
        let client = try OpenAIClient(baseURL: "https://example.test/v1", apiKey: "k", session: URLSession(configuration: config))
        // The deadline's clock is short, so it fires at once instead of after five seconds.
        let a = Agent(client: client, model: "m", limits: limits, sleep: { _ in },
                      deadlineSleep: { _ in try await Task.sleep(for: .milliseconds(100)) })
        do {
            _ = try await a.run([.user("hi")])
            Issue.record("should have timed out")
        } catch let error as APIError {
            guard case .timedOut = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(OutcomeProtocol.count == 1)
    }

    // MARK: No brain

    @Test func aPocketImpWithoutABrainAnswersAtOnceWithWhatToDo() async throws {
        OutcomeProtocol.reset([.hang])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeProtocol.self]
        let imp = PocketImp(name: "Pip")
        let brain = PocketBrain(secrets: MemorySecrets(), session: URLSession(configuration: config))
        let started = Date()
        let answer = try await brain.ask("hello", of: imp)
        #expect(answer.turn.failed)
        #expect(answer.turn.reply.contains("settings"))
        #expect(answer.memory == nil)
        #expect(OutcomeProtocol.count == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func theMissingBrainMessageSaysWhereToFixIt() {
        let text = APIError.needsBrain(imp: "Pip").localizedDescription
        #expect(text.contains("Pip") && text.contains("Brain"))
        #expect(!text.contains("—") && !text.contains(";"))
    }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}
