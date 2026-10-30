import Foundation
import Testing
@testable import ImpKit

/// Answers `DenClient` requests from a closure instead of the network.
final class DenStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            request.httpBody = data
        }
        Self.seen.append(request)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Length": String(body.count)]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Challenges made, solved and verified by the `altcha` 1.1 crate the Den uses (secret "test-secret").
private struct Vector {
    let challenge: String
    let counter: UInt32
    let derivedKey: String
    /// The payload the crate itself writes for the solution.
    let payload: String
}

private let vectors: [Vector] = [
    Vector(
        challenge: #"{"parameters":{"algorithm":"PBKDF2/SHA-256","cost":1000,"data":{"scope":"accounts"},"expiresAt":1893456000,"keyLength":16,"keyPrefix":"00","nonce":"b6670ab6193079ee96b84cfcfd4490bf","salt":"ae3c3bcfa8c339c98c1e6934eea7732f"},"signature":"29baeec8ca7722e462d8775d6730c07b31ea686abca1dda65ae3ff5fcdfb31b5"}"#,
        counter: 166, derivedKey: "00a03f0953bcf673c259018265f72218",
        payload: #"{"challenge":{"parameters":{"algorithm":"PBKDF2/SHA-256","cost":1000,"data":{"scope":"accounts"},"expiresAt":1893456000,"keyLength":16,"keyPrefix":"00","nonce":"b6670ab6193079ee96b84cfcfd4490bf","salt":"ae3c3bcfa8c339c98c1e6934eea7732f"},"signature":"29baeec8ca7722e462d8775d6730c07b31ea686abca1dda65ae3ff5fcdfb31b5"},"solution":{"counter":166,"derivedKey":"00a03f0953bcf673c259018265f72218"}}"#),
    // An odd prefix: one hex digit.
    Vector(
        challenge: #"{"parameters":{"algorithm":"PBKDF2/SHA-256","cost":400,"keyLength":32,"keyPrefix":"0","nonce":"ac999021c8234926182b0e3b8388e7b5","salt":"379c433ac0306a48aaed4664d4004f94"},"signature":"8e004c02c5905419418bf4593c9509d5b7540556bd04ad82ad49f0636f7dfba5"}"#,
        counter: 6, derivedKey: "024ead4faf2aaa1c0e6e5ddc5f9b2aed8a744d60e05ec01f6c6988bf9f7ffa91",
        payload: #"{"challenge":{"parameters":{"algorithm":"PBKDF2/SHA-256","cost":400,"keyLength":32,"keyPrefix":"0","nonce":"ac999021c8234926182b0e3b8388e7b5","salt":"379c433ac0306a48aaed4664d4004f94"},"signature":"8e004c02c5905419418bf4593c9509d5b7540556bd04ad82ad49f0636f7dfba5"},"solution":{"counter":6,"derivedKey":"024ead4faf2aaa1c0e6e5ddc5f9b2aed8a744d60e05ec01f6c6988bf9f7ffa91"}}"#),
    Vector(
        challenge: #"{"parameters":{"algorithm":"PBKDF2/SHA-384","cost":300,"keyLength":24,"keyPrefix":"00","nonce":"a34a5564e17466bf698779ef872abe8f","salt":"069e95a88d07d1309388e3e122f4512f"},"signature":"ad06b010c6469652342b92cc042932b3d77ade8405f8664f757d4467e54235bf"}"#,
        counter: 20, derivedKey: "00024a70c2accfa693be01ab319381a40972e85b6b1a160e",
        payload: #"{"challenge":{"parameters":{"algorithm":"PBKDF2/SHA-384","cost":300,"keyLength":24,"keyPrefix":"00","nonce":"a34a5564e17466bf698779ef872abe8f","salt":"069e95a88d07d1309388e3e122f4512f"},"signature":"ad06b010c6469652342b92cc042932b3d77ade8405f8664f757d4467e54235bf"},"solution":{"counter":20,"derivedKey":"00024a70c2accfa693be01ab319381a40972e85b6b1a160e"}}"#),
    Vector(
        challenge: #"{"parameters":{"algorithm":"PBKDF2/SHA-512","cost":300,"keyLength":32,"keyPrefix":"00","nonce":"c594d2ae70177f2a8bda27577f6091aa","salt":"986fc7d23cedd173aa6191cd850e7518"},"signature":"232cfa1dd8552d38308678e94fd1408715b97eb7671f177450c7642ef9606a1b"}"#,
        counter: 133, derivedKey: "00a04f1ba5f642cbd84c5b07ed56ce960f8b5ef12b529c3c574973bb719968ce",
        payload: #"{"challenge":{"parameters":{"algorithm":"PBKDF2/SHA-512","cost":300,"keyLength":32,"keyPrefix":"00","nonce":"c594d2ae70177f2a8bda27577f6091aa","salt":"986fc7d23cedd173aa6191cd850e7518"},"signature":"232cfa1dd8552d38308678e94fd1408715b97eb7671f177450c7642ef9606a1b"},"solution":{"counter":133,"derivedKey":"00a04f1ba5f642cbd84c5b07ed56ce960f8b5ef12b529c3c574973bb719968ce"}}"#),
]

private func challenge(_ text: String) throws -> AltchaChallenge {
    try JSONDecoder().decode(AltchaChallenge.self, from: Data(text.utf8))
}

@Suite struct AltchaTests {
    @Test func solvesWhatTheCrateSolved() async throws {
        for v in vectors {
            let solution = try await Altcha.solve(try challenge(v.challenge))
            #expect(solution.counter == v.counter)
            #expect(solution.derivedKey == v.derivedKey)
        }
    }

    @Test func thePayloadIsWhatTheCrateWrites() async throws {
        for v in vectors {
            let c = try challenge(v.challenge)
            let payload = try Altcha.payload(c, Altcha.Solution(counter: v.counter, derivedKey: v.derivedKey))
            let mine = try JSONValue(jsonString: String(decoding: try #require(Data(base64Encoded: payload)), as: UTF8.self))
            #expect(mine == (try JSONValue(jsonString: v.payload)), "same fields, same names, same values")
        }
    }

    @Test func refusesChallengesItShouldNot() async throws {
        var c = try challenge(vectors[0].challenge)
        c.parameters.expiresAt = 1_000_000
        await #expect(throws: Altcha.Failure.expired) { _ = try await Altcha.solve(c) }
        c = try challenge(vectors[0].challenge)
        c.parameters.cost = Altcha.maxCost + 1
        await #expect(throws: Altcha.Failure.unusable) { _ = try await Altcha.solve(c) }
        c = try challenge(vectors[0].challenge)
        c.parameters.nonce = "xyz"
        await #expect(throws: Altcha.Failure.unusable) { _ = try await Altcha.solve(c) }
        c = try challenge(vectors[0].challenge)
        c.parameters.keyPrefix = "zz"
        await #expect(throws: Altcha.Failure.unusable) { _ = try await Altcha.solve(c) }
    }

    @Test func aSearchThatNeverEndsCanBeCancelled() async throws {
        var c = try challenge(vectors[0].challenge)
        c.parameters.keyPrefix = String(repeating: "0", count: 30)
        c.parameters.cost = 50_000
        let task = Task { try await Altcha.solve(c) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite struct DenNameTests {
    @Test func handlesComeFromNames() {
        #expect(DenAccounts.handle(for: "Pip", suffix: "ab12") == "pip-ab12")
        #expect(DenAccounts.handle(for: "Zoë the  Great!", suffix: "ab12") == "zoe-the-great-ab12")
        #expect(DenAccounts.handle(for: "!!!", suffix: "ab12") == "imp-ab12")
        #expect(DenAccounts.handle(for: "", suffix: "ab12") == "imp-ab12")
        let long = DenAccounts.handle(for: String(repeating: "wizard ", count: 20), suffix: "ab12")
        #expect(long.count <= 32 && DenName.isValid(long, range: 3...32))
    }

    @Test func otherScriptsBecomeLetters() {
        for name in ["Привет", "日本語", "Ørjan", "Łukasz", "👾"] {
            #expect(DenName.isValid(DenAccounts.handle(for: name), range: 3...32), "\(name)")
        }
        #expect(DenName.slug("Привет") == "privet")
    }

    @Test func randomSuffixesAreFourPlainCharacters() {
        let s = DenAccounts.randomSuffix()
        #expect(DenName.isValid(s, range: 4...4))
    }

    @Test func itemsNeedPlainNames() {
        #expect(DenItemID("pip-3x9k/wave")?.description == "pip-3x9k/wave")
        #expect(DenItemID(" pip-3x9k/wave\n") != nil)
        for bad in ["pip", "pip/wave/more", "../etc/x", "Pip/wave", "pip/wa ve", "pip/-wave", "p/wave", "pip/wave?x=1", "pip/%2e", ""] {
            #expect(DenItemID(bad) == nil, "\(bad)")
        }
    }
}

@Suite(.serialized) struct DenClientTests {
    let server = ImpServer("imp.example.org")!

    func client() -> DenClient {
        var config = DenClient.configuration()
        config.protocolClasses = [DenStub.self]
        DenStub.seen = []
        return DenClient(server: server, configuration: config)
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers, Data(text.utf8))
    }

    @Test func problemsBecomeTypedErrors() async throws {
        DenStub.handler = { _ in
            Self.json(#"{"type":"https://imp.example.org/v1/problems/rate-limited","title":"Too many requests","status":429,"detail":"Try again in 40 seconds."}"#,
                      status: 429, headers: ["Content-Type": "application/problem+json", "Retry-After": "40"])
        }
        let error = try await #require(throws: DenError.self) { _ = try await client().items(DenQuery()) }
        #expect(error.status == 429 && error.title == "Too many requests" && error.retryAfter == 40)
        #expect(error.localizedDescription == "Try again in 40 seconds.")
    }

    @Test func aRateLimitWithoutDetailSaysHowLong() async throws {
        DenStub.handler = { _ in Self.json(#"{"title":"Too many requests"}"#, status: 429, headers: ["Retry-After": "7"]) }
        let error = try await #require(throws: DenError.self) { _ = try await client().item(DenItemID("pip-3x9k/wave")!) }
        #expect(error.localizedDescription.hasPrefix("Too many requests") && error.localizedDescription.contains("7"))
    }

    @Test func anAnswerThatIsNotAProblemStillIsAnError() async throws {
        DenStub.handler = { _ in Self.json("<html>bad gateway</html>", status: 502) }
        let error = try await #require(throws: DenError.self) { _ = try await client().challenge() }
        #expect(error.status == 502 && error.detail == nil && error.retryAfter == nil)
    }

    @Test func requestsGoToTheServerWithTheirAuth() async throws {
        DenStub.handler = { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("PUT", _): return Self.json("{}", status: 201)
            case ("DELETE", _), ("POST", "/v1/items/pip-3x9k/wave/installs"): return (204, [:], Data())
            default: return Self.json(#"{"handle":"pip-3x9k","items":[{"handle":"pip-3x9k","slug":"wave","kind":"animation","summary":"Hi","tags":["fun"],"installs":3}]}"#)
            }
        }
        let c = client()
        let id = try #require(DenItemID("pip-3x9k/wave"))
        let created = try await c.put(id, summary: "A wave", tags: ["fun"], kit: #"{"imp":3,"animations":[]}"#, token: "den_secret")
        try await c.delete(id, token: "den_secret")
        try await c.countInstall(id)
        let account = try await c.account("pip-3x9k")
        _ = try await c.items(DenQuery(text: "wave hello", kind: "animation", sort: "popular", limit: 500))
        _ = try await c.kit(id)

        #expect(created && account.items.first?.installs == 3)
        let seen = DenStub.seen
        #expect(seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PUT /v1/items/pip-3x9k/wave", "DELETE /v1/items/pip-3x9k/wave", "POST /v1/items/pip-3x9k/wave/installs",
            "GET /v1/accounts/pip-3x9k", "GET /v1/items", "GET /v1/items/pip-3x9k/wave/kit.json"])
        #expect(seen.allSatisfy { $0.url?.host == "imp.example.org" && $0.url?.scheme == "https" })
        #expect(seen[0].value(forHTTPHeaderField: "Authorization") == "Bearer den_secret")
        #expect(seen[1].value(forHTTPHeaderField: "Authorization") == "Bearer den_secret")
        #expect(seen[2].value(forHTTPHeaderField: "Authorization") == nil && seen[3].value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONValue(jsonString: String(decoding: try #require(seen[0].httpBody), as: UTF8.self))
        #expect(body["summary"]?.string == "A wave" && body["tags"]?.array?.count == 1 && body["kit"]?["imp"] != nil)
        let query = Set(URLComponents(url: try #require(seen[4].url), resolvingAgainstBaseURL: false)?.queryItems?.map { "\($0.name)=\($0.value ?? "")" } ?? [])
        #expect(query == ["q=wave hello", "kind=animation", "sort=popular", "limit=50"])
    }

    @Test func accountsAreMadeWithTheSolvedChallenge() async throws {
        DenStub.handler = { _ in Self.json(#"{"handle":"pip-3x9k","token":"den_abc","created_at":"2026-10-30T10:00:00Z"}"#, status: 201) }
        let c = client()
        let made = try await c.createAccount(handle: "pip-3x9k", altcha: "payload")
        #expect(made.token == "den_abc")
        let request = try #require(DenStub.seen.first)
        #expect(request.httpMethod == "POST" && request.url?.path == "/v1/accounts" && request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONValue(jsonString: String(decoding: try #require(request.httpBody), as: UTF8.self))
        #expect(body["handle"]?.string == "pip-3x9k" && body["altcha"]?.string == "payload")
    }

    @Test func kitsAreHeldToTheirLimit() async throws {
        DenStub.handler = { _ in (200, [:], Data(repeating: 0x20, count: Kit.maxBytes + 1)) }
        let id = try #require(DenItemID("pip-3x9k/wave"))
        await #expect(throws: DenError.self) { _ = try await client().kit(id) }
        await #expect(throws: DenError.self) {
            _ = try await client().put(id, summary: "x", tags: [], kit: String(repeating: " ", count: Kit.maxBytes + 1), token: "t")
        }
    }

    @Test func linksAreBuiltFromTheServer() {
        let c = client()
        let id = DenItemID("pip-3x9k/wave")!
        #expect(c.page(of: id).absoluteString == "https://imp.example.org/i/pip-3x9k/wave")
        #expect(c.kitURL(of: id).absoluteString == "https://imp.example.org/v1/items/pip-3x9k/wave/kit.json")
    }

    @Test func anImpGetsAnAccountOnceAndRetriesATakenHandle() async throws {
        let attempts = Counter()
        DenStub.handler = { request in
            switch request.url?.path {
            case "/v1/challenge": return Self.json(vectors[0].challenge)
            case "/v1/accounts":
                if attempts.next() == 1 { return Self.json(#"{"title":"Handle taken","status":409}"#, status: 409) }
                let body = (try? JSONValue(jsonString: String(decoding: request.httpBody ?? Data(), as: UTF8.self))) ?? .null
                return Self.json(#"{"handle":"\#(body["handle"]?.string ?? "")","token":"den_tok"}"#, status: 201)
            default: return (404, [:], Data())
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-den-\(UUID().uuidString)")
        let accounts = DenAccounts(file: KeyFile(url: dir.appendingPathComponent("keys.json")), inKeychain: false)
        let imp = UUID(), other = UUID()
        let login = try await accounts.ensure(on: server, imp: imp, name: "Pip", client: client())
        #expect(login.token == "den_tok" && login.handle.hasPrefix("pip-"))
        #expect(DenStub.seen.filter { $0.url?.path == "/v1/accounts" }.count == 2, "one retry after the 409")

        DenStub.seen = []
        #expect(try await accounts.ensure(on: server, imp: imp, name: "Pip", client: client()) == login)
        #expect(DenStub.seen.isEmpty, "the stored account is used")
        #expect(try accounts.login(on: server, imp: other) == nil, "another Imp has none")
        #expect(try accounts.login(on: ImpServer("other.example.org")!, imp: imp) == nil, "another server has none")

        let file = try String(contentsOf: dir.appendingPathComponent("keys.json"), encoding: .utf8)
        #expect(file.contains("imp.example.org") && file.contains(imp.uuidString))
        accounts.forget(imp: imp)
        #expect(try accounts.login(on: server, imp: imp) == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct DenToolTests {
    @Test func theDenIsOptIn() {
        #expect(!ImpToolGroup.den.isOnByDefault)
        #expect(!ImpProfile.imp.uses(.den))
        let names = OwnTools.specs([.den], animations: [], imps: [], browser: false).map(\.name)
        #expect(Set(names) == [OwnTools.denSearch, OwnTools.denGet, OwnTools.denAdd, OwnTools.denShare, OwnTools.denUnshare, OwnTools.denAccount])
        #expect(names.allSatisfy { OwnTools.group(of: $0) == .den })
        #expect(OwnTools.specs([.body], animations: [], imps: [], browser: false).allSatisfy { OwnTools.group(of: $0.name) != .den })
    }

    @Test func aKitReadsAsShortLines() throws {
        let kit = try Kit.parse(#"{"imp":3,"name":"Waves","about":"Hello","animations":[{"name":"Wave","beats":[{"duration":0.5,"mood":"happy"}]}],"triggers":[{"name":"Hi","when":{"kind":"start"},"prompt":"Say hi"}]}"#)
        let text = kit.readableSummary
        #expect(text.contains("Waves") && text.contains("Animation Wave: 1 beats") && text.contains("Trigger Hi: Say hi"))
        #expect(text.hasPrefix("Written by someone else"))
    }

    @Test func itemsAreOneLineEach() {
        let item = DenItem(handle: "pip-3x9k", slug: "wave", name: "Wave", kind: "animation", summary: "A wave", tags: ["fun"], installs: 3)
        #expect(item.line == "pip-3x9k/wave · animation · Wave · A wave · #fun · 3 installs")
    }
}
