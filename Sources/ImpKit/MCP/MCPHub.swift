import Foundation

public enum MCPStatus: Hashable, Sendable {
    case connecting
    case ready(toolCount: Int, toolNames: [String])
    case failed(String)
}

/// Owns one client per enabled server and exposes all their tools to the model.
public actor MCPHub: ToolProvider {
    private struct Entry {
        var config: MCPServerConfig
        var client: MCPClient?
        var task: Task<Void, Never>?
        var specs: [ToolSpec] = []
    }

    public private(set) var status: [UUID: MCPStatus] = [:]
    private var entries: [UUID: Entry] = [:]
    private var onStatusChange: (@Sendable ([UUID: MCPStatus]) -> Void)?

    public init() {}

    /// Called with the full status table whenever it changes.
    public func setStatusHandler(_ handler: (@Sendable ([UUID: MCPStatus]) -> Void)?) {
        onStatusChange = handler
    }

    /// Reconciles running connections with `configs`.
    public func update(_ configs: [MCPServerConfig]) async {
        let wanted = Dictionary(uniqueKeysWithValues: configs.filter(\.isEnabled).map { ($0.id, $0) })
        for (id, entry) in entries where wanted[id] != entry.config {
            await drop(id)
        }
        for (id, config) in wanted where entries[id] == nil {
            status[id] = .connecting
            var entry = Entry(config: config)
            entry.task = Task { await self.connect(config) }
            entries[id] = entry
        }
        notify()
    }

    /// Connects, lists tools and disconnects. For a Settings "Test" button.
    public func test(_ config: MCPServerConfig) async -> MCPStatus {
        do {
            let client = try MCPClient(config: config)
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
            return .failed(error.localizedDescription)
        }
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

    /// Waits up to ten seconds for servers that are still connecting.
    private func settle() async {
        for _ in 0..<100 where entries.values.contains(where: { $0.client == nil && $0.task != nil }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard let target = exposed().first(where: { $0.spec.name == name }),
              let client = entries[target.server]?.client else {
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = args.isEmpty ? JSONValue.object([:]) : try JSONValue(jsonString: args)
        return try await client.callTool(name: target.tool, arguments: parsed)
    }

    // MARK: Naming

    /// OpenAI function names allow `[a-zA-Z0-9_-]{1,64}`.
    static func sanitize(_ s: String) -> String {
        let mapped = String(s.unicodeScalars.map { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-") ? Character(c) : "_"
        })
        return mapped.isEmpty ? "_" : mapped
    }

    /// `<server>__<tool>` sanitized and capped at 64 characters.
    static func exposedName(server: String, tool: String) -> String {
        String((sanitize(server) + "__" + sanitize(tool)).prefix(64))
    }

    /// Exposed specs with the (server, original tool) each maps back to. Collisions get `_2`, `_3`….
    private func exposed() -> [(spec: ToolSpec, server: UUID, tool: String)] {
        var used = Set<String>()
        var out: [(ToolSpec, UUID, String)] = []
        for entry in entries.values.sorted(by: { $0.config.name < $1.config.name }) {
            for spec in entry.specs {
                let base = Self.exposedName(server: entry.config.name, tool: spec.name)
                var name = base, n = 2
                while !used.insert(name).inserted {
                    let suffix = "_\(n)"
                    name = String(base.prefix(64 - suffix.count)) + suffix
                    n += 1
                }
                var renamed = spec
                renamed.name = name
                out.append((renamed, entry.config.id, spec.name))
            }
        }
        return out
    }

    // MARK: Connections

    private func connect(_ config: MCPServerConfig) async {
        let outcome: Result<(MCPClient, [ToolSpec]), Error>
        do {
            let client = try MCPClient(config: config)
            do {
                try await client.connect()
                outcome = .success((client, try await client.listTools()))
            } catch {
                await client.close()
                throw error
            }
        } catch {
            outcome = .failure(error)
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
            status[config.id] = .failed(error.localizedDescription)
        }
        notify()
    }

    /// A ready server went away (its process exited): its tools are no longer offered, and
    /// Settings says why.
    private func ended(_ id: UUID, client: ObjectIdentifier, _ error: MCPError) {
        guard let current = entries[id]?.client, ObjectIdentifier(current) == client else { return }
        entries[id]?.client = nil
        entries[id]?.specs = []
        status[id] = .failed(error.localizedDescription)
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

    public func call(_ name: String, arguments: String) async throws -> String {
        guard await tools().contains(where: { $0.name == name }) else { throw MCPError.badConfig("Unknown tool \(name).") }
        return try await hub.call(name, arguments: arguments)
    }
}
