import CoreGraphics
import Foundation
import ImpKit
import Observation

/// Everything that talks to models, shared by the whole troupe: services and their keys, MCP
/// tools and chat. Each request says which `Brain` (model) to use, so every Imp can have its own.
/// `nil` means the default brain. The UI never builds requests itself.
@MainActor @Observable
final class Assistant {
    /// Services with a saved key. Known without reading the keys (the Keychain is only asked whether
    /// an item is there), so launching and browsing settings never ask for the user's password.
    private var keyed: Set<UUID> = []
    /// Keys read so far, by service ID: each is read the first time a request needs it.
    @ObservationIgnored private var keys: [UUID: String] = [:]
    private(set) var ai = AIConfig()
    /// Live state of each configured MCP server.
    private(set) var toolStatus: [UUID: MCPStatus] = [:]

    @ObservationIgnored let hub = MCPHub()
    @ObservationIgnored private var servers: [MCPServerConfig] = []

    /// False for offscreen design renders: they must never read or write the user's keys.
    @ObservationIgnored private let persists: Bool
    /// Where keys are kept: a private file (the default), or the Keychain if the user asked.
    @ObservationIgnored private let file = KeyFile()
    @ObservationIgnored private var inKeychain = false
    @ObservationIgnored private var configured = false

    init(usesKeychain persists: Bool = true) {
        self.persists = persists
        let update: @Sendable ([UUID: MCPStatus]) -> Void = { [weak self] status in
            Task { @MainActor in self?.toolStatus = status }
        }
        Task { [hub] in await hub.setStatusHandler(update) }
    }

    private static func account(_ id: UUID) -> String { "service.\(id.uuidString)" }

    func hasKey(_ service: UUID) -> Bool { keyed.contains(service) }

    /// Where saved keys are, in a few words for the settings.
    var keyPlace: String { inKeychain ? "your Keychain" : "a private file on this Mac" }

    /// A key an older version saved in the Keychain, while keys now live in the file. Imp doesn't
    /// read it (that could ask for the password): paste it again, or switch the Keychain on.
    func hasKeychainKeyOnly(_ service: UUID) -> Bool {
        persists && !inKeychain && !keyed.contains(service) && Keychain.contains(Self.account(service))
    }

    /// A service's key, read on first use. From the private file that never asks anything; from the
    /// Keychain (only if the user keeps keys there) the read may ask for their password. A refusal
    /// isn't remembered: the next request asks again.
    private func key(for service: Service) throws -> String {
        guard keyed.contains(service.id) else { return "" }
        if let key = keys[service.id] { return key }
        guard persists else { return "" }
        let account = Self.account(service.id)
        guard inKeychain else {
            guard let key = file.read(account) else {
                keyed.remove(service.id)                     // removed outside Imp
                return ""
            }
            keys[service.id] = key
            return key
        }
        do {
            guard let key = try Keychain.read(account) else {
                keyed.remove(service.id)
                return ""
            }
            keys[service.id] = key
            return key
        } catch {
            throw APIError.keyDenied(service: service.label)
        }
    }

    /// Saves (or, when empty, removes) a service's key, where keys are kept.
    func setKey(_ key: String, for service: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if persists {
            let account = Self.account(service)
            if inKeychain {
                Keychain.write(trimmed, account: account)
                file.write("", account: account)
            } else {
                file.write(trimmed, account: account)
            }
        }
        if trimmed.isEmpty {
            keyed.remove(service)
            keys[service] = nil
        } else {
            keyed.insert(service)
            keys[service] = trimmed
        }
    }

    /// Moves every saved key into the Keychain, or out of it into the private file: the user just
    /// switched the setting (so the password macOS may ask for, reading them out, is expected).
    /// A key macOS won't hand over stays where it was.
    private func moveKeys(toKeychain: Bool) {
        for id in ai.services.map(\.id) {
            let account = Self.account(id)
            if toKeychain {
                guard let key = keys[id] ?? file.read(account) else { continue }
                if Keychain.write(key, account: account) { file.write("", account: account) }
            } else {
                guard Keychain.contains(account), let key = keys[id] ?? (try? Keychain.read(account)) ?? nil else { continue }
                keys[id] = key
                if file.write(key, account: account) { Keychain.write("", account: account) }
            }
        }
    }

    /// The brain has a service (with a key, unless it runs locally) and a model.
    func isReady(_ brain: Brain? = nil) -> Bool {
        guard let p = ai.service(in: brain), !ai.model(in: brain).isEmpty else { return false }
        return p.isLocal || hasKey(p.id)
    }

    var hasTools: Bool { servers.contains(where: \.isEnabled) }

    func configure(ai: AIConfig, servers: [MCPServerConfig], keychain: Bool) {
        self.ai = ai
        if persists {
            if configured, keychain != inKeychain { moveKeys(toKeychain: keychain) }
            inKeychain = keychain
            let inFile = file.all()
            keyed = Set(ai.services.map(\.id).filter {
                keychain ? Keychain.contains(Self.account($0)) : inFile[Self.account($0)] != nil
            })
        }
        configured = true
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

    /// Everything an Imp may use: its own tools (`own`: body, senses, setting itself up, the troupe),
    /// the shell in its own folder (unless switched off) and its MCP servers. The shell gets the
    /// Imp's service, key and model as environment variables.
    func tools(for imp: ImpProfile, own: ToolProvider? = nil) throws -> ToolProvider? {
        var members: [ToolProvider] = own.map { [$0] } ?? []
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
