import CoreGraphics
import Foundation
import ImpKit
import Observation

/// Everything that talks to models, shared by the whole troupe: services and their keys, MCP
/// tools and chat. Each request says which `Brain` (model) to use, so every Imp can have its own.
/// `nil` means the default brain. The UI never builds requests itself.
@MainActor @Observable
final class Assistant {
    /// Services with a key in the Keychain (the only place keys are stored). Known without
    /// reading the keys, so launching and browsing settings never ask for the user's password.
    private var keyed: Set<UUID> = []
    /// Keys read so far, by service ID: each is read the first time a request needs it.
    @ObservationIgnored private var keys: [UUID: String] = [:]
    private(set) var ai = AIConfig()
    /// Live state of each configured MCP server.
    private(set) var toolStatus: [UUID: MCPStatus] = [:]

    @ObservationIgnored let hub = MCPHub()
    @ObservationIgnored private var servers: [MCPServerConfig] = []

    /// False for offscreen design renders: they must never read or write the user's Keychain.
    @ObservationIgnored private let usesKeychain: Bool

    init(usesKeychain: Bool = true) {
        self.usesKeychain = usesKeychain
        let update: @Sendable ([UUID: MCPStatus]) -> Void = { [weak self] status in
            Task { @MainActor in self?.toolStatus = status }
        }
        Task { [hub] in await hub.setStatusHandler(update) }
    }

    private static func account(_ id: UUID) -> String { "service.\(id.uuidString)" }

    func hasKey(_ service: UUID) -> Bool { keyed.contains(service) }

    /// A service's key, read from the Keychain on first use. Only for a request the user made:
    /// the read may ask for their password. A refusal isn't remembered: the next request asks again.
    private func key(for service: Service) throws -> String {
        guard keyed.contains(service.id) else { return "" }
        if let key = keys[service.id] { return key }
        guard usesKeychain else { return "" }
        do {
            guard let key = try Keychain.read(Self.account(service.id)) else {
                keyed.remove(service.id)                     // removed outside Imp
                return ""
            }
            keys[service.id] = key
            return key
        } catch {
            throw APIError.keyDenied(service: service.label)
        }
    }

    /// Saves (or, when empty, removes) a service's key.
    func setKey(_ key: String, for service: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesKeychain { Keychain.write(trimmed, account: Self.account(service)) }
        if trimmed.isEmpty {
            keyed.remove(service)
            keys[service] = nil
        } else {
            keyed.insert(service)
            keys[service] = trimmed
        }
    }

    /// The brain has a service (with a key, unless it runs locally) and a model.
    func isReady(_ brain: Brain? = nil) -> Bool {
        guard let p = ai.service(in: brain), !ai.model(in: brain).isEmpty else { return false }
        return p.isLocal || hasKey(p.id)
    }

    var hasTools: Bool { servers.contains(where: \.isEnabled) }

    func configure(ai: AIConfig, servers: [MCPServerConfig]) {
        self.ai = ai
        if usesKeychain { keyed = Set(ai.services.map(\.id).filter { Keychain.contains(Self.account($0)) }) }
        guard servers != self.servers else { return }
        self.servers = servers
        Task { [hub] in await hub.update(servers) }
    }

    func client(for service: Service) throws -> OpenAIClient {
        let key = try key(for: service)
        if key.isEmpty && !service.isLocal { throw APIError.missingKey }
        return try OpenAIClient(baseURL: service.baseURL, apiKey: key)
    }

    /// The client for a brain's service.
    func client(brain: Brain? = nil) throws -> OpenAIClient {
        guard let service = ai.service(in: brain) else { throw APIError.noService("this brain") }
        return try client(for: service)
    }

    /// Everything an Imp may use: the shell in its own folder (unless switched off) and its MCP
    /// servers. The shell gets the Imp's service, key and model as environment variables.
    func tools(for imp: ImpProfile) throws -> ToolProvider? {
        var members: [ToolProvider] = []
        if imp.usesShell {
            let directory = Workspace.directory(for: imp.id)
            let service = ai.service(in: imp.brain)
            let environment = ShellTool.environment(name: imp.name, directory: directory, baseURL: service?.baseURL,
                                                    apiKey: try service.map { try key(for: $0) }, model: ai.model(in: imp.brain))
            members.append(ShellTool(directory: directory, environment: environment))
        }
        if !imp.servers.isEmpty { members.append(MCPScope(hub: hub, servers: Set(imp.servers))) }
        return members.isEmpty ? nil : ToolSet(members)
    }

    /// Some enabled MCP server is still starting up.
    var toolsConnecting: Bool { hasTools && toolStatus.values.contains(.connecting) }

    /// Runs a chat (with tools, if given). `onEvent` hears about each tool call as it starts and
    /// finishes and, with `stream`, the answer's text as it arrives. Returns the answer and the
    /// exchange to remember: the last message sent (the user's turn) and every one that followed
    /// (tool calls, their results, the answer).
    func chat(_ messages: [ChatMessage], brain: Brain?, tools: ToolProvider?, stream: Bool = false,
              onEvent: @escaping @MainActor (AgentEvent) -> Void = { _ in }) async throws
        -> (reply: String, exchange: [ChatMessage]) {
        let model = ai.model(in: brain)
        let client = try client(brain: brain)
        guard !model.isEmpty else { throw APIError.noModel }
        let agent = Agent(client: client, model: model, tools: tools)
        let (reply, transcript) = try await agent.run(messages, stream: stream) { event in await onEvent(event) }
        guard !reply.isEmpty else { throw APIError.emptyResponse("text") }
        return (reply, Array(transcript[max(messages.count - 1, 0)...]))
    }
}
