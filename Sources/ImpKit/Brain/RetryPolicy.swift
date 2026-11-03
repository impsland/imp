import Foundation

/// How long a model request may take and how it is retried when the network hiccups. These are the
/// defaults and the limits in one place: `ImpPreferences.requests` keeps the user's choice, and the
/// iPhone reads the same values from `UserDefaults` (`stored(in:)`).
public struct RequestLimits: Codable, Hashable, Sendable {
    /// The longest one try may take before it ends with a readable error, in seconds.
    public var timeoutSeconds: Double = 120
    /// How many times a request that failed for a passing reason is tried again.
    public var retries: Int = 3
    /// The wait before the first retry, in seconds.
    public var retryDelaySeconds: Double = 1
    /// Each wait is this many times longer than the one before.
    public var backoff: Double = 2

    public init() {}

    public static let standard = RequestLimits()

    /// Safe ranges, so a hand-edited or broken value can't switch the limits off or make them absurd.
    public var clamped: RequestLimits {
        var l = self
        l.timeoutSeconds = min(max(timeoutSeconds.isFinite ? timeoutSeconds : Self.standard.timeoutSeconds, 5), 3600)
        l.retries = min(max(retries, 0), 10)
        l.retryDelaySeconds = min(max(retryDelaySeconds.isFinite ? retryDelaySeconds : Self.standard.retryDelaySeconds, 0), 60)
        l.backoff = min(max(backoff.isFinite ? backoff : Self.standard.backoff, 1), 10)
        return l
    }

    public var policy: RetryPolicy {
        let l = clamped
        return RetryPolicy(retries: l.retries, delay: l.retryDelaySeconds, multiplier: l.backoff)
    }

    /// The names the iPhone saves them under.
    public enum Key {
        public static let timeout = "requestTimeoutSeconds"
        public static let retries = "requestRetries"
        public static let delay = "requestRetryDelaySeconds"
        public static let backoff = "requestRetryBackoff"
    }

    /// The limits saved in `defaults` (a missing value keeps its default).
    public static func stored(in defaults: UserDefaults = .standard) -> RequestLimits {
        var l = RequestLimits()
        if defaults.object(forKey: Key.timeout) != nil { l.timeoutSeconds = defaults.double(forKey: Key.timeout) }
        if defaults.object(forKey: Key.retries) != nil { l.retries = defaults.integer(forKey: Key.retries) }
        if defaults.object(forKey: Key.delay) != nil { l.retryDelaySeconds = defaults.double(forKey: Key.delay) }
        if defaults.object(forKey: Key.backoff) != nil { l.backoff = defaults.double(forKey: Key.backoff) }
        return l.clamped
    }
}

/// Which retry is coming up, for showing "Retrying 2 of 3".
public struct RetryNotice: Equatable, Sendable {
    public var attempt: Int
    public var of: Int
    /// How long it waits before trying again.
    public var delay: TimeInterval

    public init(attempt: Int, of: Int, delay: TimeInterval = 0) { self.attempt = attempt; self.of = of; self.delay = delay }

    public var text: String { String(localized: "Retrying \(attempt) of \(of)") }
}

/// When and how often a failed request is tried again. A small value: the same policy serves every
/// model request, on the Mac and on the iPhone.
public struct RetryPolicy: Equatable, Sendable {
    /// Tries after the first one.
    public var retries: Int
    public var delay: TimeInterval
    public var multiplier: Double
    /// No wait grows beyond this.
    public var maxDelay: TimeInterval

    public init(retries: Int, delay: TimeInterval, multiplier: Double, maxDelay: TimeInterval = 60) {
        self.retries = max(retries, 0); self.delay = max(delay, 0); self.multiplier = max(multiplier, 1); self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(retries: 0, delay: 0, multiplier: 1)

    /// The wait before retry number `retry` (the first retry is 1): `delay`, then longer by `multiplier` each time.
    public func delay(beforeRetry retry: Int) -> TimeInterval {
        min(delay * pow(multiplier, Double(max(retry - 1, 0))), maxDelay)
    }

    /// Whether trying again could help: the network dropped or timed out, the service is busy
    /// (429), tired (5xx) or slow to hear us (408). Never a wrong key or a bad request (the other
    /// 4xx), never a cancel.
    public func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let api = error as? APIError {
            guard case .http(let status, _) = api else { return false }
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Waits for real, and throws `CancellationError` when the task is cancelled meanwhile.
    public static let pause: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    /// Runs `operation`, trying again after a passing failure. `onRetry` hears each retry before its
    /// wait. `canRetry` can veto one (the answer already started showing: a retry would repeat it).
    /// `sleep` is injectable so tests don't wait. Cancelling stops at once with `CancellationError`.
    /// The last error is thrown as it was.
    public func run<T: Sendable>(sleep: @Sendable (TimeInterval) async throws -> Void = RetryPolicy.pause,
                                 canRetry: @Sendable () async -> Bool = { true },
                                 onRetry: @Sendable (RetryNotice) async -> Void = { _ in },
                                 operation: @Sendable () async throws -> T) async throws -> T {
        var retry = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard retry < retries, isRetryable(error), await canRetry() else { throw error }
                retry += 1
                let wait = delay(beforeRetry: retry)
                await onRetry(RetryNotice(attempt: retry, of: retries, delay: wait))
                try await sleep(wait)
            }
        }
    }
}

/// Ends a request that takes too long, with a readable error instead of an endless wait.
public enum RequestDeadline {
    /// Runs `operation` and throws `APIError.timedOut` if it hasn't finished after `seconds`.
    public static func run<T: Sendable>(seconds: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = RetryPolicy.pause,
                                        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleep(seconds)
                throw APIError.timedOut(seconds: Int(seconds.rounded()))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
