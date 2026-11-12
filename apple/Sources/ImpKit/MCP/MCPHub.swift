import Foundation
import ImpCore

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
        guard let target = exposed().first(where: { $0.spec.name == name }),
              let client = entries[target.server]?.client else {
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        return try await client.callTool(name: target.tool, argumentsJSON: arguments)
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
    public func catalog() async -> [CatalogTool] { await hub.catalog(from: servers) }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard await tools().contains(where: { $0.name == name }) else { throw MCPError.badConfig("Unknown tool \(name).") }
        return try await hub.call(name, arguments: arguments)
    }
}
