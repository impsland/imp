import Foundation

/// An OpenAI-compatible endpoint. Its API key lives in the Keychain, never here.
public struct Service: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var baseURL: String

    public init(id: UUID = UUID(), name: String, baseURL: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    /// Servers on this machine or LAN usually need no key.
    public var isLocal: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host.hasSuffix(".local")
    }

    /// What to call it: its name, or its address's host when it has none.
    public var label: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? "Unnamed service"
    }
}

/// Which model an Imp thinks with, on which service. The default lives in `AIConfig.brain`,
/// and an Imp may have its own.
public struct Brain: Codable, Hashable, Sendable {
    /// None until the user adds a service.
    public var service: UUID?
    public var model: String

    public init(service: UUID? = nil, model: String = "") {
        self.service = service
        self.model = model
    }
}

/// The user's services (shared by every Imp, keys in the Keychain) and the default brain.
/// Nothing is built in: it starts empty, and the user adds whatever OpenAI-compatible service they like.
public struct AIConfig: Codable, Hashable, Sendable {
    public var services: [Service] = []
    public var brain = Brain()

    public init() {}

    /// Adds a service. The default brain uses it if it had none.
    public mutating func add(_ service: Service) {
        services.append(service)
        if self.service() == nil { brain.service = service.id }
    }

    /// The service a brain uses (the default brain unless one is given, and a brain without a
    /// service of its own uses the default's).
    public func service(in brain: Brain? = nil) -> Service? {
        guard let id = brain?.service ?? self.brain.service else { return nil }
        return services.first { $0.id == id }
    }

    /// The model a brain thinks with (the default's when it names none).
    public func model(in brain: Brain? = nil) -> String {
        let own = brain?.model.trimmingCharacters(in: .whitespaces) ?? ""
        return own.isEmpty ? self.brain.model.trimmingCharacters(in: .whitespaces) : own
    }

    /// Removes a service. A brain that used it moves to the first remaining one (or none).
    public mutating func remove(service id: UUID) {
        services.removeAll { $0.id == id }
        brain.reassign(from: id, to: services.first?.id)
    }
}

extension Brain {
    /// Points the brain at service `new` if it used `old`.
    public mutating func reassign(from old: UUID, to new: UUID?) {
        if service == old { service = new }
    }
}
