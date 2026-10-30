import Foundation
import Network
import os

/// Network settings for Imp Link: TCP with keepalive, wrapped in TLS that only completes when both
/// sides hold the same pre-shared key (see `LinkPairing.psk`). That's the pattern Apple recommends
/// for peer-to-peer apps: no certificates to manage, mutual authentication, and encryption.
public enum LinkTLS {
    static let identity = Data("imp-link".utf8)

    /// With `hop`, the connection first goes through the Hop's handshake (below TLS), then runs the
    /// very same TLS end to end.
    public static func parameters(psk: Data, hop: HopPass? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let id = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, id as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        if let hop {
            let framer = NWProtocolFramer.Options(definition: HopFramer.definition)
            framer[HopFramer.key] = hop
            params.defaultProtocolStack.applicationProtocols.append(framer)
        }
        return params
    }
}

/// One link connection: frames out, frames in. Callbacks arrive on the channel's own queue.
public final class LinkChannel: @unchecked Sendable {   // mutable state is only touched on `queue`
    public enum State: Sendable, Equatable {
        case ready
        /// Gone for good. `why` says how, `reason` is for logs.
        case closed(Close, reason: String?)
    }

    public enum Close: Sendable, Equatable {
        /// Closed on purpose, or by the other side.
        case ended
        /// No way through: no route, refused, timed out, or the link went silent.
        case unreachable
        /// The other side answered but won't take our key (it doesn't know this pairing any more).
        case rejected
        /// The Hop turned the pairing's room away.
        case hopRefused
    }

    public let id = UUID()
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var framer = LinkFrame()
    private var isClosed = false
    private var wasReady = false
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?
    private let hop: HopPass?
    private let log = Logger(subsystem: "app.imp.Imp", category: "link")

    public var onState: (@Sendable (State) -> Void)?
    public var onFrame: (@Sendable (Data) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue? = nil, hop: HopPass? = nil) {
        self.connection = connection
        self.hop = hop
        self.queue = queue ?? DispatchQueue(label: "app.imp.link.\(UUID().uuidString.prefix(8))")
    }

    /// Dials `endpoint` (a Bonjour service, or host and port) with the pairing's key.
    public convenience init(to endpoint: NWEndpoint, psk: Data) {
        self.init(connection: NWConnection(to: endpoint, using: LinkTLS.parameters(psk: psk)))
    }

    /// Dials the Mac through the pairing's Hop. Nil when the pairing has none.
    public convenience init?(hopOf pairing: LinkPairing) {
        guard let address = pairing.hop.flatMap(HopAddress.init), let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
        let pass = HopPass(room: Hop.Room(secret: pairing.secret), role: .phone)
        self.init(connection: NWConnection(host: NWEndpoint.Host(address.host), port: port,
                                           using: LinkTLS.parameters(psk: pairing.psk, hop: pass)), hop: pass)
    }

    /// True once the Hop spliced this connection to the Mac.
    public var isThroughHop: Bool { hop?.status == .go }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.wasReady = true
                self.lastHeard = Date()
                self.watch()
                self.onState?(.ready)
                self.receive()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                // Unreachable for now (no route, refused, TLS said no): don't hang around waiting.
                self.finish(error)
            case .cancelled:
                self.finish(.ended, nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends one message. Silently dropped once closed.
    public func send<T: Encodable>(_ value: T) {
        let data: Data
        do { data = try LinkFrame.encode(value) } catch {
            log.error("couldn't encode a link message: \(String(describing: error), privacy: .public)")
            return
        }
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(error) }
            })
        }
    }

    /// Sends one message and returns once the network has taken it (or the link is gone), so a
    /// big stream (a file in parts) goes at the network's pace instead of piling up in memory.
    /// False when the link closed first.
    @discardableResult
    public func sendAndWait<T: Encodable & Sendable>(_ value: T) async -> Bool {
        guard let data = try? LinkFrame.encode(value) else { return false }
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self, !self.isClosed else { return done.resume(returning: false) }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(error) }
                    done.resume(returning: error == nil)
                })
            }
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.finish(.ended, nil)
        }
    }

    /// Closes a link that has been silent too long: a half-dead connection (the other side left
    /// the network, or slept) would otherwise only be noticed after TCP gives up, minutes later.
    private func watch() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + LinkProtocol.silenceLimit / 4, repeating: LinkProtocol.silenceLimit / 4)
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastHeard) > LinkProtocol.silenceLimit else { return }
            self.connection.cancel()
            self.finish(.unreachable, "silent for too long")
        }
        watchdog = timer
        timer.resume()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            self.lastHeard = Date()
            if let data, !data.isEmpty {
                do {
                    for frame in try self.framer.feed(data) { self.onFrame?(frame) }
                } catch {
                    self.connection.cancel()
                    return self.finish(.ended, "bad frame: \(error)")
                }
            }
            if let error { return self.finish(error) }
            if complete { self.connection.cancel(); return self.finish(.ended, "closed by the other side") }
            self.receive()
        }
    }

    /// The connection failed: before it was ever ready, a TLS error means someone answered and
    /// refused us, anything else means we never got through.
    private func finish(_ error: NWError) {
        if hop?.status == .rejected { return finish(.hopRefused, "the Hop turned this pairing away") }
        if !wasReady, case .tls = error { return finish(.rejected, error.localizedDescription) }
        finish(wasReady ? .ended : .unreachable, error.localizedDescription)
    }

    private func finish(_ why: Close, _ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.cancel()
        watchdog = nil
        if case .failed = connection.state {} else if connection.state != .cancelled { connection.cancel() }
        onState?(.closed(why, reason: reason))
        onState = nil
        onFrame = nil
    }
}
