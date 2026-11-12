import Foundation

/// The two ways to give an Imp a Brain: **Remote** (a service in the cloud, with a key) and **Local** (a model
/// server on your own computer). Offered when adding a service and on the first run, on every platform.
/// They are data (`spec/presets/services.json`, compiled in as `Presets.servicesJSON`): each pre-fills its
/// address, which stays freely editable, so any OpenAI-compatible address works. Nothing in Imp depends on them.
public struct ServicePreset: Codable, Sendable, Hashable, Identifiable {
    /// `remote` or `local`.
    public let id: String
    public let baseURL: String
    /// Where to go to get started with it: the key page, a model to download.
    public let link: URL
    /// It runs on your own computer (no key needed, and on the iPhone it's reached over the network).
    public let isLocal: Bool
    /// An SF Symbol for its choice.
    public let symbol: String

    private enum CodingKeys: String, CodingKey {
        case id, baseURL, link, symbol
        case isLocal = "local"
    }

    public init(id: String, baseURL: String, link: URL, isLocal: Bool, symbol: String) {
        self.id = id; self.baseURL = baseURL; self.link = link; self.isLocal = isLocal; self.symbol = symbol
    }

    private struct File: Decodable {
        let `default`: String
        let services: [ServicePreset]
    }

    private static let file: File? = try? JSONDecoder().decode(File.self, from: Data(Presets.servicesJSON.utf8))

    /// Remote, then Local, as the data file lists them.
    public static let all: [ServicePreset] = file?.services ?? []

    /// The one picked to begin with (Remote).
    public static var standard: ServicePreset? { all.first { $0.id == file?.default } ?? all.first }

    /// "Remote" or "Local", what its choice is called.
    public var title: String { String(localized: isLocal ? "firstrun.service.local" : "firstrun.service.remote") }

    public static var remote: ServicePreset? { all.first { !$0.isLocal } }
    public static var local: ServicePreset? { all.first { $0.isLocal } }

    /// The preset an address belongs to: the same host (any machine for a local one) and port.
    public static func matching(_ address: String) -> ServicePreset? {
        guard let wanted = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = wanted.host?.lowercased() else { return nil }
        return all.first { preset in
            guard let parts = URLComponents(string: preset.baseURL) else { return false }
            if preset.isLocal { return parts.port == wanted.port && wanted.port != nil }
            return parts.host?.lowercased() == host
        }
    }

    /// The preset's address on another machine (`host`, a `.local` name or an address): how the
    /// iPhone reaches a service running on the Mac.
    public func baseURL(onHost host: String) -> String {
        guard isLocal, var parts = URLComponents(string: baseURL) else { return baseURL }
        parts.host = host
        return parts.string ?? baseURL
    }

    /// A host name that shows the user what to type, for a local preset on a phone: the address of the computer.
    public static let exampleHost = "my-mac.local"

    /// Whether `text` is an address Imp can talk to: http or https, with a host.
    public static func isValidAddress(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil,
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether `text` points at a computer of the user's own: this one, or one on the home network.
    public static func isOwnComputer(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}
