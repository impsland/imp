import Foundation
import Testing
@testable import ImpKit

/// Runs `Tests/Fixtures/retry-policy.json`, which other clients read too.
@Suite struct RetryPolicyVectorTests {
    static var vectors: [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-policy.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    static func policy(_ p: [String: Any]) -> RetryPolicy {
        RetryPolicy(retries: p["retries"] as! Int, delay: (p["delay"] as! NSNumber).doubleValue,
                    multiplier: (p["multiplier"] as! NSNumber).doubleValue,
                    maxDelay: (p["maxDelay"] as? NSNumber)?.doubleValue ?? 60)
    }

    @Test func delaysFollowTheVectors() throws {
        let cases = try #require(Self.vectors["delays"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let p = Self.policy(c["policy"] as! [String: Any])
            let wait = (c["wait"] as! NSNumber).doubleValue
            #expect(p.delay(beforeRetry: c["retry"] as! Int) == wait, "\(c)")
        }
    }

    @Test func limitsAreClampedAsInTheVectors() throws {
        let cases = try #require(Self.vectors["limits"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let s = c["stored"] as! [String: Any], k = c["clamped"] as! [String: Any]
            var l = RequestLimits()
            l.timeoutSeconds = (s["timeoutSeconds"] as! NSNumber).doubleValue
            l.retries = s["retries"] as! Int
            l.retryDelaySeconds = (s["retryDelaySeconds"] as! NSNumber).doubleValue
            l.backoff = (s["backoff"] as! NSNumber).doubleValue
            let clamped = l.clamped
            #expect(clamped.timeoutSeconds == (k["timeoutSeconds"] as! NSNumber).doubleValue, "\(c["name"]!)")
            #expect(clamped.retries == k["retries"] as! Int, "\(c["name"]!)")
            #expect(clamped.retryDelaySeconds == (k["retryDelaySeconds"] as! NSNumber).doubleValue, "\(c["name"]!)")
            #expect(clamped.backoff == (k["backoff"] as! NSNumber).doubleValue, "\(c["name"]!)")
            #expect(l.policy == Self.policy(c["policy"] as! [String: Any]), "\(c["name"]!)")
        }
    }

    @Test func errorsAreRetryableAsInTheVectors() throws {
        let cases = try #require(Self.vectors["errors"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let policy = RetryPolicy(retries: 3, delay: 1, multiplier: 2)
        for c in cases {
            let e = c["error"] as! [String: Any]
            let error: Error
            switch e["kind"] as! String {
            case "http": error = APIError.http(status: e["status"] as! Int, message: "")
            case "url": error = URLError(Self.code(e["code"] as! String))
            case "cancelled": error = CancellationError()
            case "missingKey": error = APIError.missingKey
            default: error = NSError(domain: "other", code: 1)
            }
            #expect(policy.isRetryable(error) == (c["retryable"] as! Bool), "\(e)")
        }
    }

    static func code(_ name: String) -> URLError.Code {
        switch name {
        case "timedOut": .timedOut
        case "networkConnectionLost": .networkConnectionLost
        case "notConnectedToInternet": .notConnectedToInternet
        case "cannotConnectToHost": .cannotConnectToHost
        case "cannotFindHost": .cannotFindHost
        case "dnsLookupFailed": .dnsLookupFailed
        case "secureConnectionFailed": .secureConnectionFailed
        case "badURL": .badURL
        case "cancelled": .cancelled
        case "serverCertificateUntrusted": .serverCertificateUntrusted
        default: .unknown
        }
    }
}
