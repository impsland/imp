import Foundation
import ImpCore
import Observation

/// One request the issuer makes. The key is sent as a bearer token when it is set.
public struct IssuerRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var body: String? = nil
    public var bearer: String? = nil
}

/// What came back: the status, the body and the raw `Retry-After` header.
public struct IssuerResponse: Sendable, Equatable {
    public var status: Int
    public var body: String
    public var retryAfter: String?

    public init(status: Int, body: String, retryAfter: String? = nil) {
        self.status = status; self.body = body; self.retryAfter = retryAfter
    }
}

/// Where the issuer is. A failure says whether trying again can help and how many seconds to wait first.
public enum KeyIssuerState: Equatable, Sendable {
    case idle
    case issuing
    case issued
    case failed(retryable: Bool, wait: Int?)
}

/// Gets the key of a build that comes with a model service, once per install, and presets the service:
/// its address, the first model it lists and its host as the name. The network is a closure, so tests need none.
@MainActor @Observable
public final class KeyIssuer {
    public let settings: ResellerSettings
    public private(set) var state = KeyIssuerState.idle
    /// What the service said, for the "Details" of a failure. Never shown by default and never a key.
    public private(set) var detail: String?
    /// The service as it was stored, once issued. The key is kept by the store and nowhere else.
    public private(set) var brain: FirstRunBrain?

    @ObservationIgnored private let http: @Sendable (IssuerRequest) async throws -> IssuerResponse
    @ObservationIgnored private let store: @MainActor (FirstRunBrain) throws -> Void
    @ObservationIgnored private let existing: @MainActor () -> FirstRunBrain?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retryAt: Date?
    /// A key that was issued but could not be stored or used yet: another try never asks for a second one.
    @ObservationIgnored private var issuedKey: String?

    /// `existing` is the service of an earlier issuance on this install, when there is one.
    /// `store` keeps the service and its key where a manual key is kept, and throws when it cannot.
    public init(settings: ResellerSettings,
                http: @escaping @Sendable (IssuerRequest) async throws -> IssuerResponse,
                existing: @escaping @MainActor () -> FirstRunBrain? = { nil },
                store: @escaping @MainActor (FirstRunBrain) throws -> Void,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.settings = settings
        self.http = http
        self.existing = existing
        self.store = store
        self.now = now
    }

    /// Whether "Try again" does something now: the last attempt failed in a way that can change and any wait is over.
    public var canRetry: Bool {
        guard case .failed(let retryable, _) = state, retryable else { return false }
        return retryAt.map { now() >= $0 } ?? true
    }

    /// Begins, once. An install that already has its service is issued at once, with no request.
    public func start() {
        guard state == .idle else { return }
        if let known = existing() {
            brain = known
            state = .issued
            return
        }
        launch()
    }

    /// Tries again after a failure, with a new challenge.
    public func retry() {
        guard canRetry else { return }
        launch()
    }

    /// Waits for the attempt that is running.
    public func settled() async { await task?.value }

    public func cancel() { task?.cancel() }

    private func launch() {
        state = .issuing
        detail = nil
        retryAt = nil
        task = Task { await attempt() }
    }

    private func attempt() async {
        do {
            let key: String
            if let issued = issuedKey { key = issued } else { key = try await requestKey() }
            issuedKey = key
            let model = try await firstModel(key: key)
            let kept = FirstRunBrain(name: settings.host, baseURL: settings.baseUrl, model: model, key: key, isLocal: false)
            try store(kept)
            brain = kept
            issuedKey = nil
            state = .issued
        } catch is CancellationError {
            state = .idle
        } catch let failure as IssuanceFailure {
            fail(failure)
        } catch let error as URLError where error.code == .cancelled {
            state = .idle
        } catch let error as KeyNotSaved {
            detail = error.localizedDescription
            state = .failed(retryable: true, wait: nil)
        } catch {
            fail(.Network(message: error.localizedDescription))
        }
    }

    private func requestKey() async throws -> String {
        let challenge = try await send(IssuerRequest(method: "GET", url: issuanceChallengeUrl(issuanceUrl: settings.issuanceUrl)))
        let required = try parseIssuanceChallenge(status: UInt16(clamping: challenge.status), body: challenge.body, retryAfter: challenge.retryAfter)
        // Solving the challenge is work for the CPU: it stays off the main actor.
        let body = try await Task.detached { try issuanceSignupBody(challenge: required) }.value
        let issued = try await send(IssuerRequest(method: "POST", url: settings.issuanceUrl, body: body))
        return try parseIssuedKey(status: UInt16(clamping: issued.status), body: issued.body, retryAfter: issued.retryAfter)
    }

    private func firstModel(key: String) async throws -> String {
        let answer = try await send(IssuerRequest(method: "GET", url: settings.baseUrl + "/models", bearer: key))
        guard (200..<300).contains(answer.status) else {
            throw IssuanceFailure.Server(status: UInt16(clamping: answer.status), message: chatErrorMessage(body: answer.body))
        }
        struct List: Decodable { struct Item: Decodable { var id: String }
            var data: [Item] }
        guard let list = try? JSONDecoder().decode(List.self, from: Data(answer.body.utf8)), !list.data.isEmpty else {
            throw IssuanceFailure.Malformed(message: chatErrorMessage(body: answer.body))
        }
        return FirstRunModel.suggested(from: list.data.map { $0.id })
    }

    private func send(_ request: IssuerRequest) async throws -> IssuerResponse {
        do { return try await http(request) } catch is CancellationError { throw CancellationError() } catch {
            throw IssuanceFailure.Network(message: error.localizedDescription)
        }
    }

    private func fail(_ failure: IssuanceFailure) {
        var wait: Int?
        switch failure {
        case .RateLimited(let seconds, let message):
            wait = seconds.map { Int(clamping: $0) }
            detail = message
        case .Disabled(let message), .Rejected(let message), .Malformed(let message), .Network(let message): detail = message
        case .Server(_, let message): detail = message
        }
        retryAt = wait.map { now().addingTimeInterval(TimeInterval($0)) }
        state = .failed(retryable: issuanceFailureIsRetryable(failure: failure), wait: wait)
    }
}

extension IssuerRequest {
    /// The request for URLSession.
    public var urlRequest: URLRequest? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        return request
    }
}

extension KeyIssuer {
    /// The real network: URLSession.
    public static func live(session: URLSession = .shared) -> @Sendable (IssuerRequest) async throws -> IssuerResponse {
        { request in
            guard let urlRequest = request.urlRequest else { throw URLError(.badURL) }
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return IssuerResponse(status: http.statusCode, body: String(decoding: data, as: UTF8.self),
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
    }
}
