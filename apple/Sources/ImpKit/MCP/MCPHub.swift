import Foundation
import ImpCore

public enum MCPStatus: Hashable, Sendable {
    case connecting
    case ready(toolCount: Int, toolNames: [String])
    case failed(String)
    /// The server asks for a sign-in the person has not given (or it ran out).
    case needsSignIn
}

/// Owns one client per enabled server and exposes all their tools to the model.
public actor MCPHub: ToolProvider {
    private struct Entry {
        var config: MCPServerConfig
        var client: MCPClient?
        var task: Task<Void, Never>?
        var specs: [ToolSpec] = []
    }

    /// The tool name of the stand-in a server offers while it needs a sign-in.
    static let signInTool = "sign_in"

    public private(set) var status: [UUID: MCPStatus] = [:]
    private var entries: [UUID: Entry] = [:]
    private var onStatusChange: (@Sendable ([UUID: MCPStatus]) -> Void)?

    private let auth: MCPAuthStore
    private var signIn: (@Sendable (MCPServerConfig) async throws -> Void)?

    private let session: URLSession

    public init(auth: MCPAuthStore = .standard) { self.auth = auth; session = .shared }
    init(auth: MCPAuthStore, session: URLSession) { self.auth = auth; self.session = session }

    /// What to do when a tool call needs a sign-in: the app shows the browser sheet and returns
    /// when it is done, or throws when the person cancelled or it failed.
    public func setSignIn(_ handler: (@Sendable (MCPServerConfig) async throws -> Void)?) { signIn = handler }

    /// Connects `id` again (after a sign-in or sign-out). Never opens the sign-in sheet.
    public func reconnect(_ id: UUID) async {
        guard let config = entries[id]?.config else { return }
        entries[id]?.task?.cancel()
        let old = entries[id]?.client
        entries[id]?.client = nil
        entries[id]?.specs = []
        status[id] = .connecting
        entries[id]?.task = Task { await self.connect(config, interactive: false) }
        notify()
        await old?.close()
    }

    /// Runs the sign-in for `id` (the sheet, through the handler), connects again and says what
    /// came of it, in words for the model. The stand-in tool's body.
    private func signInAndReport(_ id: UUID) async -> String {
        guard let config = entries[id]?.config else { return String(localized: "Unknown tool.") }
        guard let signIn else { return Self.openImp(config.name) }
        do {
            try await signIn(config)
        } catch MCPSignInError.notAttended {
            return Self.openImp(config.name)
        } catch is CancellationError {
            return String(localized: "The sign-in to \(config.name) was cancelled. Its tools are not available.")
        } catch MCPSignInError.cancelled {
            return String(localized: "The sign-in to \(config.name) was cancelled. Its tools are not available.")
        } catch {
            return String(localized: "The sign-in to \(config.name) failed: \(error.localizedDescription)")
        }
        await reconnect(id)
        await entries[id]?.task?.value
        if case .ready(_, let names)? = status[id] {
            let exposedNames = exposed().filter { $0.server == id }.map(\.spec.name)
            return String(localized: "Signed in to \(config.name). Its tools are now available: \((exposedNames.isEmpty ? names : exposedNames).joined(separator: ", ")).")
        }
        return String(localized: "Signed in to \(config.name), but its tools could not be listed.")
    }

    private static func openImp(_ server: String) -> String {
        String(localized: "Open Imp and sign in to \(server) in Tools")
    }

    private static func standIn(for config: MCPServerConfig) -> ToolSpec {
        ToolSpec(name: signInTool,
                 description: String(localized: "\(config.name) needs the user to sign in before its tools are available. Call this when the user wants to use \(config.name); it opens the sign-in page."),
                 inputSchema: (try? JSONValue(jsonString: #"{"type":"object","properties":{}}"#)) ?? .object([:]))
    }

    /// Called with the full status table whenever it changes.
    public func setStatusHandler(_ handler: (@Sendable ([UUID: MCPStatus]) -> Void)?) {
        onStatusChange = handler
    }

    /// Reconciles running connections with `configs`. `userInitiated`: every changed server was
    /// added, switched on or edited by the person (see `update(_:signInNow:)`).
    public func update(_ configs: [MCPServerConfig], userInitiated: Bool) async {
        await update(configs, signInNow: userInitiated ? Set(configs.map(\.id)) : [])
    }

    /// Reconciles running connections with `configs`. `signInNow`: the servers the person just
    /// added, switched on or edited (never the app starting, a background refresh, or a change that
    /// came from another device). Such a server that answers "sign in" gets the sign-in sheet at
    /// once and is connected again when it is done. Any other stays "Sign-in needed".
    public func update(_ configs: [MCPServerConfig], signInNow: Set<UUID> = []) async {
        let wanted = Dictionary(uniqueKeysWithValues: configs.filter(\.isEnabled).map { ($0.id, $0) })
        for (id, entry) in entries where wanted[id] != entry.config {
            await drop(id)
        }
        for (id, config) in wanted where entries[id] == nil {
            status[id] = .connecting
            var entry = Entry(config: config)
            entry.task = Task { await self.connect(config, interactive: signInNow.contains(id)) }
            entries[id] = entry
        }
        notify()
    }

    /// Connects, lists tools and disconnects. For a Settings "Test" button.
    public func test(_ config: MCPServerConfig) async -> MCPStatus {
        do {
            let client = try MCPClient(config: config, auth: auth, session: session)
            do {
                try await client.connect()
                let names = try await client.listTools().map(\.name)
                await client.close()
                return .ready(toolCount: names.count, toolNames: names)
            } catch {
                await client.close()
                throw error
            }
        } catch {
            return Self.status(for: error)
        }
    }

    private static func status(for error: Error) -> MCPStatus {
        if case MCPError.needsSignIn = error { return .needsSignIn }
        return .failed(error.localizedDescription)
    }

    // MARK: ToolProvider

    /// Tools of all ready servers, waiting briefly for in-flight connections.
    public func tools() async -> [ToolSpec] {
        await settle()
        return exposed().map(\.spec)
    }

    /// Tools of some servers only (an Imp's own selection).
    public func tools(from servers: Set<UUID>) async -> [ToolSpec] {
        await settle()
        return exposed().filter { servers.contains($0.server) }.map(\.spec)
    }

    /// The tools with their registry entries (`mcp.<server>.<tool>`), of some servers or all.
    public func catalog(from servers: Set<UUID>?) async -> [CatalogTool] {
        await settle()
        return exposed().filter { servers?.contains($0.server) ?? true }.map { item in
            let entry = ToolEntry(id: item.id, name: item.spec.name, group: item.group, title: item.tool)
            return CatalogTool(entry: entry, spec: item.spec)
        }
    }

    public func catalog() async -> [CatalogTool] { await catalog(from: nil) }

    /// Waits up to ten seconds for servers that are still connecting.
    private func settle() async {
        for _ in 0..<100 where entries.values.contains(where: { $0.client == nil && $0.task != nil }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard let target = exposed().first(where: { $0.spec.name == name }) else {
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        if entries[target.server]?.client == nil, status[target.server] == .needsSignIn, target.tool == Self.signInTool {
            return await signInAndReport(target.server)
        }
        guard let client = entries[target.server]?.client else {
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        do {
            return try await client.callTool(name: target.tool, argumentsJSON: arguments)
        } catch MCPError.needsSignIn {
            // Ask the person to sign in (they can cancel), then try the call once more.
            guard let config = entries[target.server]?.config, let signIn else {
                throw MCPError.signInRequired(server: entries[target.server]?.config.name ?? "")
            }
            do { try await signIn(config) } catch is CancellationError { throw CancellationError() } catch {
                throw MCPError.signInRequired(server: config.name)
            }
            do {
                return try await client.callTool(name: target.tool, argumentsJSON: arguments)
            } catch MCPError.needsSignIn {
                throw MCPError.signInRequired(server: config.name)
            }
        }
    }

    // MARK: Naming

    /// A server name as it appears in tool ids (the core's rule).
    static func sanitize(_ s: String) -> String { ImpCore.toolServerKey(name: s) }

    /// The tools of the running servers as the model is offered them. The core names them: servers
    /// in name order, two tools with one name numbered, ids and groups for the registry.
    private func exposed() -> [(spec: ToolSpec, server: UUID, tool: String, id: String, group: String)] {
        let list = Array(entries.values)
        let offered = ImpCore.mcpExpose(servers: list.map { McpServerTools(name: $0.config.name, tools: $0.specs.map(\.name)) })
        return offered.compactMap { item in
            let entry = list[Int(item.server)]
            guard var spec = entry.specs.first(where: { $0.name == item.tool }) else { return nil }
            spec.name = item.name
            return (spec, entry.config.id, item.tool, item.id, item.group)
        }
    }

    // MARK: Connections

    private func open(_ config: MCPServerConfig) async -> Result<(MCPClient, [ToolSpec]), Error> {
        do {
            let client = try MCPClient(config: config, auth: auth, session: session)
            do {
                try await client.connect()
                return .success((client, try await client.listTools()))
            } catch {
                await client.close()
                throw error
            }
        } catch {
            return .failure(error)
        }
    }

    private func connect(_ config: MCPServerConfig, interactive: Bool) async {
        var outcome = await open(config)
        // The person just asked for this server and it wants a sign-in: ask at once, then try again.
        if interactive, case .failure(MCPError.needsSignIn) = outcome, let signIn,
           entries[config.id]?.config == config, !Task.isCancelled {
            entries[config.id]?.specs = [Self.standIn(for: config)]
            status[config.id] = .needsSignIn
            notify()
            if (try? await signIn(config)) != nil, entries[config.id]?.config == config, !Task.isCancelled {
                outcome = await open(config)
            }
        }
        // Ignore results for entries that were dropped or replaced meanwhile.
        guard entries[config.id]?.config == config, !Task.isCancelled else {
            if case .success(let (client, _)) = outcome { await client.close() }
            return
        }
        switch outcome {
        case .success(let (client, specs)):
            entries[config.id]?.client = client
            entries[config.id]?.specs = specs
            entries[config.id]?.task = nil
            status[config.id] = .ready(toolCount: specs.count, toolNames: specs.map(\.name))
            let key = ObjectIdentifier(client)
            await client.onEnd { [weak self] error in Task { await self?.ended(config.id, client: key, error) } }
        case .failure(let error):
            entries[config.id]?.task = nil
            let state = Self.status(for: error)
            entries[config.id]?.specs = state == .needsSignIn ? [Self.standIn(for: config)] : []
            status[config.id] = state
        }
        notify()
    }

    /// A ready server went away (its process exited): its tools are no longer offered, and
    /// Settings says why.
    private func ended(_ id: UUID, client: ObjectIdentifier, _ error: MCPError) {
        guard let current = entries[id]?.client, ObjectIdentifier(current) == client else { return }
        entries[id]?.client = nil
        let state = Self.status(for: error)
        entries[id]?.specs = state == .needsSignIn ? entries[id].map { [Self.standIn(for: $0.config)] } ?? [] : []
        status[id] = state
        notify()
    }

    private func drop(_ id: UUID) async {
        let entry = entries.removeValue(forKey: id)
        status[id] = nil
        entry?.task?.cancel()
        await entry?.client?.close()
    }

    private func notify() { onStatusChange?(status) }
}

/// The hub seen through one Imp's eyes: only the tools of the servers it uses.
public struct MCPScope: ToolProvider {
    public let hub: MCPHub
    public let servers: Set<UUID>

    public init(hub: MCPHub, servers: Set<UUID>) {
        self.hub = hub; self.servers = servers
    }

    public func tools() async -> [ToolSpec] { await hub.tools(from: servers) }
    public func catalog() async -> [CatalogTool] { await hub.catalog(from: servers) }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard await tools().contains(where: { $0.name == name }) else { throw MCPError.badConfig("Unknown tool \(name).") }
        return try await hub.call(name, arguments: arguments)
    }
}
