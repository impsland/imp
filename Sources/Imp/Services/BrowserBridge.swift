import AppKit
import Network
import Observation
import os
import ImpKit

/// A tiny local WebSocket server the Imp browser extension connects to. It tells Imp which
/// page the active tab shows and finds elements on it. Loopback only; extension origins only.
@MainActor @Observable
final class BrowserBridge {
    enum Failure: LocalizedError {
        case notConnected, timeout
        var errorDescription: String? {
            switch self {
            case .notConnected: "No browser extension is connected. The user can add the Imp extension (Settings › Tools › Browser) and keep the browser open."
            case .timeout: "The browser extension didn't answer in time."
            }
        }
    }

    static let shared = BrowserBridge()
    /// Fixed loopback port the extension dials.
    nonisolated static let port: UInt16 = 47_823

    /// The active tab's page changed (new URL, or another tab/window came to the front).
    @ObservationIgnored var onPage: ((BrowserPage) -> Void)?
    /// The last page reported (nil when no extension is connected).
    private(set) var page: BrowserPage?
    var isConnected: Bool { !peers.isEmpty }

    private final class Peer: @unchecked Sendable { // `browser` is touched on the main actor only
        let id = UUID()
        let connection: NWConnection
        var browser = "Browser"
        init(_ c: NWConnection) { connection = c }
    }

    @ObservationIgnored private let queue = DispatchQueue(label: "app.imp.Imp.bridge")
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "bridge")
    @ObservationIgnored private var listener: NWListener?
    private var peers: [Peer] = []          // oldest first
    @ObservationIgnored private var active: UUID?               // the peer that spoke last
    @ObservationIgnored private var pending: [String: CheckedContinuation<BridgeInbound, Error>] = [:]
    @ObservationIgnored private var pendingPeer: [String: UUID] = [:]

    private init() {}

    func start() {
        guard listener == nil else { return }
        // Browsers send `Origin` on a WebSocket handshake and web pages can't forge or drop it
        // from script, so allowing only extension origins keeps websites (which can reach
        // 127.0.0.1) out. Anything else is refused during the handshake, before any message.
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue, handler: Self.vet)
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.accept(c) }
            }
            l.stateUpdateHandler = { [log] state in
                if case .failed(let e) = state { log.error("listener failed: \(e.localizedDescription, privacy: .public)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log.error("couldn't listen on \(Self.port): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Handshake gate: accept extension origins, refuse the rest.
    private nonisolated static func vet(_ subprotocols: [String], _ headers: [(name: String, value: String)]) -> NWProtocolWebSocket.Response {
        var origin: String?
        for header in headers where header.name.lowercased() == "origin" { origin = header.value }
        if Bridge.isAllowedOrigin(origin) { return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
        Logger(subsystem: "app.imp.Imp", category: "bridge").notice("refused a connection with origin \(origin ?? "none", privacy: .public)")
        return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
    }

    func stop() {
        listener?.cancel(); listener = nil
        for p in peers { p.connection.cancel() }
        peers = []; active = nil
        failAll(Failure.notConnected)
        setPage(nil, notify: false)
    }

    /// Where an element is on screen (Cocoa coordinates), or nil if nothing matches.
    func locate(_ query: String) async throws -> CGRect? {
        let id = UUID().uuidString
        let reply = try await request(id: id, .locate(id: id, query: query))
        guard case .located(_, let rect?) = reply else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return Bridge.cocoaRect(rect, primaryScreenHeight: height)
    }

    /// The active tab's visible text, trimmed to `limit` characters.
    func pageText(limit: Int = 20_000) async throws -> String {
        let id = UUID().uuidString
        let reply = try await request(id: id, .text(id: id, limit: limit))
        guard case .text(_, let text) = reply else { return "" }
        return String(text.prefix(limit))
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { @MainActor in self?.ready(peer) }
            case .failed, .cancelled: Task { @MainActor in self?.drop(peer) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func ready(_ peer: Peer) {
        guard !peers.contains(where: { $0 === peer }) else { return }
        peers.append(peer)
        active = peer.id
        log.info("extension connected (\(self.peers.count) total)")
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self] data, context, _, error in
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let closed = meta?.opcode == .close
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty, meta?.opcode == .text { self.handle(data, from: peer) }
                if error != nil || closed { peer.connection.cancel(); self.drop(peer) }
                else { self.receive(peer) }
            }
        }
    }

    private func drop(_ peer: Peer) {
        guard let i = peers.firstIndex(where: { $0 === peer }) else { return }
        peers.remove(at: i)
        peer.connection.cancel()
        for (id, owner) in pendingPeer where owner == peer.id { finish(id, .failure(Failure.notConnected)) }
        if active == peer.id { active = peers.last?.id }
        log.info("extension disconnected (\(self.peers.count) left)")
        if peers.isEmpty { setPage(nil, notify: false) }
    }

    private func handle(_ data: Data, from peer: Peer) {
        guard let message = BridgeInbound.decode(data) else { return }
        switch message {
        case .hello(let browser, _):
            peer.browser = String(browser.prefix(40))
            active = peer.id
        case .page(let url, let title):
            active = peer.id
            setPage(BrowserPage(url: String(url.prefix(2_000)), title: String(title.prefix(300)), browser: peer.browser), notify: true)
        case .located(let id, _), .text(let id, _):
            // Only the peer that was asked may answer.
            if pendingPeer[id] == peer.id { finish(id, .success(message)) }
        case .pong: break
        }
    }

    private func setPage(_ new: BrowserPage?, notify: Bool) {
        page = new
        if notify, let new { onPage?(new) }
    }

    // MARK: Requests

    private func request(id: String, _ message: BridgeOutbound) async throws -> BridgeInbound {
        guard let peer = peers.first(where: { $0.id == active }) ?? peers.last else { throw Failure.notConnected }
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            pendingPeer[id] = peer.id
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "bridge", metadata: [meta])
            peer.connection.send(content: message.encoded(), contentContext: ctx, isComplete: true,
                                 completion: .contentProcessed { [weak self] error in
                if error != nil { Task { @MainActor in self?.finish(id, .failure(Failure.notConnected)) } }
            })
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(id, .failure(Failure.timeout))
            }
        }
    }

    /// Resolves a pending request exactly once; later calls (timeout after reply, etc.) are no-ops.
    private func finish(_ id: String, _ result: Result<BridgeInbound, Error>) {
        pendingPeer[id] = nil
        guard let c = pending.removeValue(forKey: id) else { return }
        c.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
    }
}
