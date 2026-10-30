import Foundation
import Network
import os

/// Network settings for Imp Link: TCP with keepalive, wrapped in TLS that only completes when both
/// sides hold the same pre-shared key (see `LinkPairing.psk`). That's the pattern Apple recommends
/// for peer-to-peer apps: no certificates to manage, mutual authentication, and encryption.
public enum LinkTLS {
    static let identity = Data("imp-link".utf8)

    public static func parameters(psk: Data) -> NWParameters {
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
        return params
    }
}

/// One link connection: frames out, frames in. Callbacks arrive on the channel's own queue.
public final class LinkChannel: @unchecked Sendable {   // mutable state is only touched on `queue`
    public enum State: Sendable, Equatable {
        case ready
        /// Gone for good (refused, wrong key, dropped). `reason` for logs.
        case closed(reason: String?)
    }

    public let id = UUID()
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var framer = LinkFrame()
    private var isClosed = false
    private let log = Logger(subsystem: "app.imp.Imp", category: "link")

    public var onState: (@Sendable (State) -> Void)?
    public var onFrame: (@Sendable (Data) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "app.imp.link.\(UUID().uuidString.prefix(8))")
    }

    /// Dials `endpoint` (a Bonjour service, or host and port) with the pairing's key.
    public convenience init(to endpoint: NWEndpoint, psk: Data) {
        self.init(connection: NWConnection(to: endpoint, using: LinkTLS.parameters(psk: psk)))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?(.ready)
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // Unreachable for now (no route, refused, TLS said no): don't hang around waiting.
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
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
                if let error { self?.finish(error.localizedDescription) }
            })
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.finish(nil)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.framer.feed(data) { self.onFrame?(frame) }
                } catch {
                    self.connection.cancel()
                    return self.finish("bad frame: \(error)")
                }
            }
            if let error { return self.finish(error.localizedDescription) }
            if complete { self.connection.cancel(); return self.finish("closed by the other side") }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        if case .failed = connection.state {} else if connection.state != .cancelled { connection.cancel() }
        onState?(.closed(reason: reason))
        onState = nil
        onFrame = nil
    }
}
