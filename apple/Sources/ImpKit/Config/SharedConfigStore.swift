import Foundation
import ImpCore
import os

/// The shared configuration on disk (`docs/architecture/configuration.md`), read and written through the core:
/// `imp.json` and `auth.json` in the config folder, the agents in `~/.agents/agents`. The app's own model
/// (`ImpPreferences`) is mapped to and from it by `SharedMapping`.
///
/// Reading remembers what it saw. Saving works out what differs from that and writes only it, as merge
/// patches the core applies after reading the files again under its lock, so what the terminal app changed in
/// the meantime stays.
public final class SharedConfigStore: @unchecked Sendable {
    public let configDir: URL
    public let homeDir: URL
    private let paths: ConfigPaths
    private let lock = NSLock()
    private var base = SharedSnapshot()
    private var last = SharedRead()
    private var seen = ""
    private let log = Logger(subsystem: "app.imp.Imp", category: "config")

    public init(configDir: URL, homeDir: URL) {
        self.configDir = configDir
        self.homeDir = homeDir
        paths = ConfigPaths(configDir: configDir.path, homeDir: homeDir.path)
    }

    /// The person's own folders, found as `imp` finds them (`$IMP_CONFIG_HOME`, `$XDG_CONFIG_HOME/imp`, `~/.config/imp`).
    public static func standard() -> SharedConfigStore {
        if let p = configDefaultPaths() { return SharedConfigStore(configDir: URL(fileURLWithPath: p.configDir), homeDir: URL(fileURLWithPath: p.homeDir)) }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return SharedConfigStore(configDir: home.appending(path: ".config/imp"), homeDir: home)
    }

    /// Reads everything again. The shared part of the preferences comes back. The next `save` is worked out against it.
    @discardableResult
    public func load() -> SharedRead {
        let snapshot = SharedSnapshot(configLoad(paths: paths))
        let read = SharedMapping.read(snapshot)
        lock.withLock { base = snapshot; last = read; seen = snapshot.stamp }
        for d in snapshot.diagnostics { log.warning("config: \(d, privacy: .public)") }
        return read
    }

    public var diagnostics: [String] { lock.withLock { base.diagnostics } }

    /// Whether a file changed since this store read or wrote it (names, sizes and times only: nothing is read).
    public func changedOutside() -> Bool { lock.withLock { seen } != configStamp(paths: paths) }

    /// Writes what differs between `prefs` and what was read. Returns whether any file was written.
    @discardableResult
    public func save(_ prefs: ImpPreferences) throws -> Bool {
        let (snapshot, previous) = lock.withLock { (base, last) }
        let write = SharedMapping.write(prefs, base: snapshot, previous: previous)
        var next = snapshot
        for r in write.renames {
            try configRenameAgent(paths: paths, old: r.old, new: r.new)
            next.agents[r.new] = next.agents[r.old]
            next.agents[r.old] = nil
            if let moved = next.config["imps"]?[r.old] { next.config = next.config.merged(with: .object(["imps": .object([r.old: .null, r.new: moved])])) }
        }
        for name in write.removals {
            try configRemoveAgent(paths: paths, name: name)
            next.agents[name] = nil
        }
        for (name, patch) in write.agents {
            try configUpdateAgent(paths: paths, name: name, patchJson: patch.text)
            next.agents[name] = (next.agents[name] ?? .object([:])).merged(with: patch)
        }
        if let patch = write.config {
            try configUpdate(paths: paths, patchJson: patch.text)
            next.config = next.config.merged(with: patch)
        }
        let wrote = !write.renames.isEmpty || !write.removals.isEmpty || !write.agents.isEmpty || write.config != nil
        lock.withLock {
            base = next
            last.providers = write.providers; last.files = write.files; last.servers = write.servers
            if wrote { seen = configStamp(paths: paths) }
        }
        return wrote
    }

    /// The files that make up the configuration as the app knows it: `imp.json`, `auth.json`, the lock and the
    /// agent file of each Imp. Other agents of `~/.agents` are not the app's to remove.
    public func files() -> [URL] {
        let imps = lock.withLock { Array(last.files.values) }
        return ["imp.json", "auth.json", "imp.json.lock"].map { configDir.appending(path: $0) }
            + imps.map { homeDir.appending(path: ".agents/agents/\($0).md") }
    }

    // MARK: Where things are

    /// The agent file of an Imp, once it is in the files.
    public func agentFile(for imp: UUID) -> URL? {
        lock.withLock { last.files[imp] }.map { homeDir.appending(path: ".agents/agents/\($0).md") }
    }

    /// The name of an Imp's agent file, once it is in the files.
    public func agentName(for imp: UUID) -> String? { lock.withLock { last.files[imp] } }

    /// What the Imp's rules say about a tool call (`toolID` is its registry id, when it has one): the core's
    /// verdict on its action and resource. The files are read now, so a rule edited a moment ago counts.
    public func gate(agent: String, toolID: String?, name: String, arguments: String) -> GateVerdict {
        configGate(paths: paths, agent: agent, toolId: toolID, toolName: name, argumentsJson: arguments)
    }

    /// Adds `allow` for `action` on `resource` to the agent's own rules.
    public func allowAlways(agent: String, action: String, resource: String) throws {
        try configAllowAlways(paths: paths, agent: agent, action: action, resource: resource)
    }

    /// The skills and commands in `~/.agents`: the app lists them and does not edit them.
    public func library() -> ConfigLibrary { configLibrary(paths: paths) }

    // MARK: Keys (`auth.json`)

    /// The provider a service is, once it is in the files.
    public func providerID(for service: UUID) -> String? { lock.withLock { last.providers[service] } }

    /// Whether the service has a key (`options.apiKey` or the saved one), as of the last read. Reads no key.
    public func hasKey(for service: UUID) -> Bool {
        lock.withLock { last.providers[service].map(base.keyed.contains) ?? false }
    }

    /// The key a service is used with. Read when a request needs it.
    public func key(for service: UUID) -> String? { providerID(for: service).flatMap { authKey(paths: paths, provider: $0) } }

    /// Saves (an empty one removes) the key typed for a service, in `auth.json`, readable by the person only.
    /// False when the service is not in the files yet or the file could not be written.
    @discardableResult
    public func setKey(_ key: String, for service: UUID) -> Bool {
        guard let id = providerID(for: service), (try? authSetKey(paths: paths, provider: id, key: key)) != nil else { return false }
        lock.withLock {
            if key.isEmpty { base.keyed.remove(id) } else { base.keyed.insert(id) }
            seen = configStamp(paths: paths)
        }
        return true
    }

    // MARK: Tool server sign-ins (`auth.json`)

    /// The server (by name) an address is, so its sign-in is kept where `imp` looks for it.
    func serverName(forURL url: String) -> String? {
        lock.withLock {
            (base.config["mcp"]?.object ?? [:]).first { $0.value["url"]?.string?.trimmingCharacters(in: .whitespaces) == url }?.key
        }
    }

    /// The sign-ins of the tool servers, kept in the same `auth.json`.
    public var mcpAuth: MCPAuthStore { MCPAuthStore(backend: ConfigMCPAuth(paths: paths, serverName: { [weak self] in self?.serverName(forURL: $0) })) }
}

/// Tool server sign-ins in `auth.json`, by the server's name, so `imp` and the app are signed in together.
struct ConfigMCPAuth: MCPAuthBackend {
    let paths: ConfigPaths
    let serverName: @Sendable (String) -> String?
    private let pending = PendingClients()

    init(paths: ConfigPaths, serverName: @escaping @Sendable (String) -> String?) {
        self.paths = paths
        self.serverName = serverName
    }

    private func key(_ url: String) -> String { serverName(url) ?? url }

    func auth(for url: String) -> McpAuth? {
        let k = key(url)
        return ((try? authMcpAll(paths: paths)) ?? []).first { $0.server == k }?.auth
    }

    func hasAuth(for url: String) -> Bool { auth(for: url) != nil }

    func save(_ auth: McpAuth, for url: String) -> Bool { (try? authMcpSet(paths: paths, server: key(url), auth: auth)) != nil }

    func forget(_ url: String) { try? authMcpSet(paths: paths, server: key(url), auth: nil) }

    /// The client id registered with an authorization server: the one a sign-in saved for it, else one just registered.
    func clientID(issuer: String) -> String? {
        ((try? authMcpAll(paths: paths)) ?? []).first { $0.auth.issuer == issuer && !$0.auth.clientId.isEmpty }?.auth.clientId
            ?? pending.get(issuer)
    }

    func setClientID(_ id: String, issuer: String) { pending.set(id, issuer) }
}

private final class PendingClients: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String: String] = [:]
    func get(_ issuer: String) -> String? { lock.withLock { ids[issuer] } }
    func set(_ id: String, _ issuer: String) { lock.withLock { ids[issuer] = id } }
}
