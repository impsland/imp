import CoreGraphics
import Foundation
import ImpKit
import Observation

/// Everything that talks to models, shared by the whole troupe: services and their keys, MCP
/// tools and chat. Each request says which `Brain` (model) to use, so every Imp can have its own.
/// `nil` means the default brain. The UI never builds requests itself.
@MainActor @Observable
final class Assistant {
    /// Services with a saved key (`auth.json`, or `options.apiKey` in `imp.json`), as of the last `configure`.
    /// Known without reading the keys, so launching and browsing settings read no secret.
    private var keyed: Set<UUID> = []
    private(set) var ai = AIConfig()
    /// How long a request may take and how it is retried (`ImpPreferences.requests`).
    private(set) var limits = RequestLimits.standard
    /// Live state of each configured MCP server.
    private(set) var toolStatus: [UUID: MCPStatus] = [:]

    @ObservationIgnored let hub: MCPHub
    @ObservationIgnored private var servers: [MCPServerConfig] = []

    /// The shared configuration, where keys and tool server sign-ins are kept. Nil for offscreen design
    /// renders: they must never read or write the user's keys.
    @ObservationIgnored private let config: SharedConfigStore?
    @ObservationIgnored private let auth: MCPAuthStore

    init(config: SharedConfigStore?) {
        self.config = config
        auth = config?.mcpAuth ?? MCPAuthStore.empty
        hub = MCPHub(auth: auth)
        let update: @Sendable ([UUID: MCPStatus]) -> Void = { [weak self] status in
            Task { @MainActor in self?.toolStatus = status }
        }
        Task { [hub] in await hub.setStatusHandler(update) }
        // A tool call that needs a sign-in opens the browser sheet. The person can cancel it.
        let signIn: @Sendable (MCPServerConfig) async throws -> Void = { [weak self] server in
            guard let self else { throw MCPSignInError.cancelled }
            try await self.signInOnly(to: server)
        }
        Task { [hub] in await hub.setSignIn(signIn) }
    }

    // MARK: Signing in to tool servers

    /// The servers (by id) the person is signed in to. Only checks that a sign-in is saved: the
    /// token itself is not read.
    private(set) var signedIn: Set<UUID> = []
    @ObservationIgnored private let presenter = WebAuthPresenter()

    func refreshSignedIn() {
        signedIn = Set(servers.filter { $0.transport == .http && auth.hasAuth(for: $0.url.trimmingCharacters(in: .whitespaces)) }.map(\.id))
    }

    /// Shows the browser sheet for `server` and keeps the sign-in. Throws when cancelled or failed.
    @MainActor func signIn(to server: MCPServerConfig) async throws {
        try await signInOnly(to: server)
        await hub.reconnect(server.id)
    }

    /// The sheet and the saved sign-in, without connecting again (the hub does that itself).
    @MainActor func signInOnly(to server: MCPServerConfig) async throws {
        let url = server.url.trimmingCharacters(in: .whitespaces)
        defer { refreshSignedIn() }
        try await MCPSignIn(store: auth, presenter: presenter).signIn(to: url)
    }

    func signInAndReconnect(_ server: MCPServerConfig) async -> String? {
        do { try await signIn(to: server); return nil }
        catch MCPSignInError.cancelled { return nil }
        catch { return error.localizedDescription }
    }

    func signOut(of server: MCPServerConfig) async {
        await MCPSignIn(store: auth, presenter: presenter).signOut(of: server.url.trimmingCharacters(in: .whitespaces))
        refreshSignedIn()
        await hub.reconnect(server.id)
    }

    func hasKey(_ service: UUID) -> Bool { keyed.contains(service) }

    /// A service's key, read from `auth.json` when a request needs it.
    private func key(for service: Service) throws -> String {
        guard keyed.contains(service.id) else { return "" }
        guard let key = config?.key(for: service.id) else {
            keyed.remove(service.id)                         // removed outside Imp
            return ""
        }
        return key
    }

    /// Saves (or, when empty, removes) a service's key in `auth.json`, readable by the person only. False
    /// when it could not be written (or the service is not saved yet): nothing is then remembered.
    @discardableResult
    func setKey(_ key: String, for service: UUID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let config, !config.setKey(trimmed, for: service) { return false }
        if trimmed.isEmpty { keyed.remove(service) } else { keyed.insert(service) }
        return true
    }

    /// The brain has a service (with a key, unless it runs locally) and a model.
    func isReady(_ brain: Brain? = nil) -> Bool {
        guard let p = ai.service(in: brain), !ai.model(in: brain).isEmpty else { return false }
        return p.isLocal || hasKey(p.id)
    }

    /// Why `brain` can't answer right now, in words that say what to do (nil: it can). Cheap: it
    /// never reads a key, so a request can check it before it starts and fail at once.
    func problem(with brain: Brain?, imp name: String) -> APIError? {
        guard let service = ai.service(in: brain) else { return .needsBrain(imp: name) }
        if ai.model(in: brain).isEmpty { return .noModel }
        if !service.isLocal, !hasKey(service.id) { return .missingKey }
        return nil
    }

    var hasTools: Bool { servers.contains(where: \.isEnabled) }

    /// Servers the person just added or switched on. The next `configure` lets those, and only
    /// those, open the sign-in sheet if they ask for one.
    var signInRequests: Set<UUID> = []

    func configure(ai: AIConfig, servers: [MCPServerConfig], limits: RequestLimits = .standard) {
        self.ai = ai
        self.limits = limits
        if let config { keyed = Set(ai.services.map(\.id).filter(config.hasKey)) }
        // Only servers the person just turned on may open the sign-in sheet (`AppModel.changeByPerson`).
        let signInNow = signInRequests
        signInRequests = []
        guard servers != self.servers else { refreshSignedIn(); return }
        self.servers = servers
        refreshSignedIn()
        Task { [hub] in await hub.update(servers, signInNow: signInNow) }
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

    /// Everything an Imp may use: its own tools (`own`: body, senses, setting itself up, the troupe, computer control, the Den), the skills,
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
        if !imp.servers.isEmpty { members.append(MCPScope(hub: hub, servers: Set(imp.servers), workspace: Workspace.directory(for: imp.id))) }
        members.append(ComputerToolHost(control: computerControl(for: imp.id)))
        if let skills = config?.agentLibrary.skillTools { members.append(skills) }
        // What is switched off for the Imp (groups and single tools) is applied here, once.
        return ToolSet(members, selection: imp.toolSelection)
    }

    /// Each Imp's computer control, kept so it remembers its last look between calls and requests.
    private var computerControls: [UUID: ComputerControl] = [:]

    private func computerControl(for imp: UUID) -> ComputerControl {
        if let existing = computerControls[imp] { return existing }
        let control = ComputerControl()
        computerControls[imp] = control
        return control
    }

    /// Some enabled MCP server is still starting up.
    var toolsConnecting: Bool { hasTools && toolStatus.values.contains(.connecting) }

    /// Runs a chat (with tools, if given). `onEvent` hears about each tool call as it starts and
    /// finishes and, with `stream`, the answer's text as it arrives. Returns the answer and the
    /// exchange to remember: the last message sent (the user's turn) and every one that followed
    /// (tool calls, their results, the answer).
    func chat(_ messages: [ChatMessage], brain: Brain?, tools: ToolProvider?, gate: ToolGate? = nil, stream: Bool = false,
              onEvent: @escaping @MainActor (AgentEvent) -> Void = { _ in }) async throws
        -> (reply: String, exchange: [ChatMessage]) {
        let model = ai.model(in: brain)
        let client = try client(brain: brain)
        guard !model.isEmpty else { throw APIError.noModel }
        let agent = Agent(client: client, model: model, tools: tools, gate: gate, limits: limits)
        let (reply, transcript) = try await agent.run(messages, stream: stream) { event in await onEvent(event) }
        guard !reply.isEmpty else { throw APIError.emptyResponse("text") }
        return (reply, Array(transcript[max(messages.count - 1, 0)...]))
    }
}
