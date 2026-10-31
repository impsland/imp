import Foundation

/// A well-known OpenAI-compatible service, offered as a one-tap address when adding a service (on the
/// Mac) or giving a pocket Imp a brain (on the iPhone), with a link to where you get a key or a model.
/// Nothing in Imp depends on them.
public struct ServicePreset: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let baseURL: String
    /// Where to go to get started with it: the key page, a model to download, the project.
    public let link: URL
    /// It runs on your own computer (no key needed, and on the iPhone it's reached over the network).
    public let isLocal: Bool

    public init(name: String, baseURL: String, link: URL, isLocal: Bool) {
        self.name = name; self.baseURL = baseURL; self.link = link; self.isLocal = isLocal
    }

    public static let all: [ServicePreset] = [
        ServicePreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                      link: URL(string: "https://openrouter.ai/workspaces/default/keys")!, isLocal: false),
        ServicePreset(name: "Ollama", baseURL: "http://localhost:11434/v1",
                      link: URL(string: "https://ollama.com/library/qwen3.8")!, isLocal: true),
        ServicePreset(name: "LM Studio", baseURL: "http://localhost:1234/v1",
                      link: URL(string: "https://lmstudio.ai/models/qwen3.8")!, isLocal: true),
        ServicePreset(name: "OmniRoute", baseURL: "http://localhost:20128/v1",
                      link: URL(string: "https://github.com/spilneo/RouteBar")!, isLocal: true),
    ]

    /// The ones the iPhone offers: a cloud service, and a router that runs on your Mac and reaches
    /// every model you've set up there (the phone gets to it by the Mac's name on your network).
    public static let phone: [ServicePreset] = all.filter { ["OpenRouter", "OmniRoute"].contains($0.name) }

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
}
