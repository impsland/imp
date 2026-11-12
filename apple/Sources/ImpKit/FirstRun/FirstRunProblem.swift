import Foundation
import ImpCore

/// What a platform throws from the first run's `adopt` when the key of a Brain that just worked could not be stored.
public struct KeyNotSaved: Error, Equatable, Sendable {
    public init() {}
}

/// Why the first run could not go on, as the plain sentence that says what to do next.
public enum FirstRunProblem: Equatable, Sendable {
    /// The key field is empty.
    case emptyKey
    /// No model is picked.
    case noModel
    /// The key was refused.
    case wrongKey
    /// A local server did not answer: it is not running, or the address is wrong.
    case noServer
    /// The device has no network.
    case noNetwork
    /// The service does not have the model.
    case modelMissing
    /// It was too slow.
    case timeout
    /// A service is out of reach.
    case unreachable
    /// The check worked, but the key could not be saved.
    case keyNotSaved
    /// The typed address is not an http or https address.
    case badAddress
    /// Nothing more is known.
    case generic

    /// What went wrong with a request, from the error it ended with. `local` is a model server on a computer.
    public static func from(_ error: Error, local: Bool) -> FirstRunProblem {
        if error is KeyNotSaved { return .keyNotSaved }
        if let api = error as? APIError {
            switch api {
            case .missingKey, .keyDenied: return .wrongKey
            case .noModel, .noService, .needsBrain: return .noModel
            case .timedOut: return .timeout
            case .badURL: return local ? .noServer : .unreachable
            case .http(let status, _):
                switch status {
                case 401, 403: return .wrongKey
                case 404: return .modelMissing
                case 408, 504: return .timeout
                default: return .generic
                }
            case .emptyResponse: return .generic
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return .timeout
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return local ? .noServer : .noNetwork
            case .cancelled: return .generic
            default: return local ? .noServer : .unreachable
            }
        }
        return local ? .noServer : .unreachable
    }

    /// The key of the sentence in the strings.
    public var key: String {
        switch self {
        case .emptyKey: "firstrun.error.empty_key"
        case .noModel: "firstrun.error.no_model"
        case .wrongKey: "error.brain.key"
        case .noServer: "error.brain.local"
        case .noNetwork: "error.brain.offline"
        case .modelMissing: "error.brain.model"
        case .timeout: "error.brain.timeout"
        case .unreachable: "error.brain.unreachable"
        case .keyNotSaved: "firstrun.error.key_not_saved"
        case .badAddress: "firstrun.error.address"
        case .generic: "error.generic"
        }
    }

    /// The sentence, naming the service and the model where it needs to.
    public func sentence(service: String, model: String) -> String {
        func text(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }
        switch self {
        case .wrongKey, .timeout, .unreachable: return String(format: text(key), service)
        case .modelMissing: return String(format: text(key), service, model)
        default: return text(key)
        }
    }
}
