import Foundation

/// An OpenAI-compatible endpoint, and the model every Imp on it thinks with unless it picks its
/// own. Its API key lives apart (`KeyFile` or the Keychain), never here.
public struct Service: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var baseURL: String
    /// The model Imps on this service use when they don't name one. Empty: none chosen yet.
    public var model: String {
        get { defaultModel ?? "" }
        set { defaultModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue }
    }
    /// Optional, so services saved before it existed still load.
    private var defaultModel: String?

    public init(id: UUID = UUID(), name: String, baseURL: String, model: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
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
        return URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? String(localized: "Unnamed service")
    }
}

/// Which model an Imp thinks with, on which service. The default lives in `AIConfig.brain`,
/// and an Imp may have its own.
public struct Brain: Codable, Hashable, Sendable {
    /// None: the default brain's service (and in the default brain, none until the user adds one).
    public var service: UUID?
    /// Empty: the service's model (`Service.model`).
    public var model: String

    public init(service: UUID? = nil, model: String = "") {
        self.service = service
        self.model = model
    }
}

/// The user's services (shared by every Imp, each with its model) and the default brain: its
/// service is the one new Imps think with. Nothing is built in: it starts empty, and the user adds
/// whatever OpenAI-compatible service they like.
public struct AIConfig: Codable, Hashable, Sendable {
    public var services: [Service] = []
    /// The service new Imps (and Imps that never picked one) use. Its `model` is only what older
    /// versions saved there (see `ImpPreferences.upgrade()`): models now belong to services.
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

    /// The model a brain thinks with: its own, else its service's, else (from an older version)
    /// the default brain's.
    public func model(in brain: Brain? = nil) -> String {
        for name in [brain?.model, service(in: brain)?.model, self.brain.model] {
            let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// The service new Imps use.
    public var defaultService: UUID? {
        get { service()?.id }
        set { brain.service = newValue }
    }

    /// Sets the model every Imp on a service uses unless it picks its own.
    public mutating func setModel(_ model: String, for service: UUID) {
        guard let i = services.firstIndex(where: { $0.id == service }) else { return }
        services[i].model = model
    }

    /// Removes a service. If it was the default, the first remaining one is the default now (or
    /// none), and the model an older version saved with it goes too: it was that service's.
    public mutating func remove(service id: UUID) {
        services.removeAll { $0.id == id }
        if brain.service == id {
            brain.service = services.first?.id
            brain.model = ""
        }
    }
}

extension Brain {
    /// The brain after service `old` is gone: one that used it follows the default brain again, its
    /// service and that service's model (a model named for `old` would only fail somewhere else).
    /// Nil when it used `old`, and so does one that followed the default with a model of its own when
    /// `old` was the default. Unchanged otherwise.
    public func without(service old: UUID, wasDefault: Bool) -> Brain? {
        if service == old { return nil }
        if service == nil, wasDefault { return nil }
        return self
    }
}
