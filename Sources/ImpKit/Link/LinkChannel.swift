import Foundation
import Network
import os

/// One link connection: frames out, and a stream of what happened (ready, frames in, closed). The
/// stream is ordered, so whoever reads it sees a connection's whole life in sequence.
public final class LinkChannel: @unchecked Sendable {   // mutable state is only touched on `queue`
    public enum Event: Sendable, Equatable {
        /// TLS is up. `binding` is the exporter value every proof of the handshake is tied to.
        case ready(binding: Data)
        case frame(Data)
        /// Gone for good. `why` says how, `reason` is for logs.
        case closed(Close, reason: String?)
    }

    public enum Close: Sendable, Equatable {
        /// Closed on purpose, or by the other side.
        case ended
        /// No way through: no route, refused, timed out, or the connection went silent.
        case unreachable
        /// The other side answered but TLS failed: it doesn't share our door key.
        case rejected
        /// The Hop turned the room away.
        case hopRefused
    }

    public let id = UUID()
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    let connection: NWConnection
    private let queue: DispatchQueue
    private var framer = LinkFrame()
    private var isClosed = false
    private var wasReady = false
    private var lastHeard = Date()
    private var timer: DispatchSourceTimer?
    private let hop: HopPass?
    private let pingInterval: TimeInterval
    private let silenceLimit: TimeInterval
    private let log = Logger(subsystem: "app.imp.Imp", category: "link")

    public init(connection: NWConnection, hop: HopPass? = nil, pingInterval: TimeInterval = LinkProtocol.pingInterval,
                silenceLimit: TimeInterval = LinkProtocol.silenceLimit) {
        self.connection = connection
        self.hop = hop
        self.pingInterval = pingInterval
        self.silenceLimit = silenceLimit
        queue = DispatchQueue(label: "app.imp.link.\(UUID().uuidString.prefix(8))")
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Dials `endpoint` (a Bonjour service, or host and port) with the host's door key.
    public convenience init(to endpoint: NWEndpoint, door: Data, pingInterval: TimeInterval = LinkProtocol.pingInterval,
                            silenceLimit: TimeInterval = LinkProtocol.silenceLimit) {
        self.init(connection: NWConnection(to: endpoint, using: LinkCrypto.parameters(door: door)),
                  pingInterval: pingInterval, silenceLimit: silenceLimit)
    }

    /// Dials a host through its Hop, as a guest of its room.
    public convenience init?(hop address: HopAddress, host: Data, door: Data, pingInterval: TimeInterval = LinkProtocol.pingInterval,
                             silenceLimit: TimeInterval = LinkProtocol.silenceLimit) {
        guard let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
        let pass = HopPass(Hop.Credentials(guestOf: host, door: door))
        self.init(connection: NWConnection(host: NWEndpoint.Host(address.host), port: port, using: LinkCrypto.parameters(door: door, hop: pass)),
                  hop: pass, pingInterval: pingInterval, silenceLimit: silenceLimit)
    }

    /// True once the Hop spliced this connection to the host.
    public var isThroughHop: Bool { hop?.status == .go }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let binding = LinkCrypto.binding(of: self.connection) else {
                    self.connection.cancel()
                    return self.finish(.unreachable, "no TLS binding")
                }
                self.wasReady = true
                self.lastHeard = Date()
                self.keepWatch()
                self.continuation.yield(.ready(binding: binding))
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
    public func send(_ message: LinkMessage) {
        let data: Data
        do { data = try LinkFrame.encode(message) } catch {
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

    /// Sends one message and returns once the network has taken it (or the connection is gone), so a
    /// big stream (a file in parts) goes at the network's pace instead of piling up in memory.
    /// False when the connection closed first.
    @discardableResult
    public func sendAndWait(_ message: LinkMessage) async -> Bool {
        guard let data = try? LinkFrame.encode(message) else { return false }
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

    /// Sends a last message, then closes once the network has taken it.
    public func goodbye(_ message: LinkMessage) {
        guard let data = try? LinkFrame.encode(message) else { return close() }
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
                self?.finish(.ended, nil)
            })
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.finish(.ended, nil)
        }
    }

    /// Pings while connected, and closes a connection that has been silent too long: a half-dead one
    /// (the other side left the network, or slept) would otherwise only be noticed after TCP gives up.
    private func keepWatch() {
        let tick = max(0.05, min(pingInterval, silenceLimit / 4))
        var lastPing = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            if Date().timeIntervalSince(self.lastHeard) > self.silenceLimit {
                self.connection.cancel()
                return self.finish(.unreachable, "silent for too long")
            }
            if Date().timeIntervalSince(lastPing) >= self.pingInterval {
                lastPing = Date()
                self.send(.ping)
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            self.lastHeard = Date()
            if let data, !data.isEmpty {
                do {
                    for frame in try self.framer.feed(data) { self.continuation.yield(.frame(frame)) }
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
        if hop?.status == .rejected { return finish(.hopRefused, "the Hop turned this room away") }
        if !wasReady, case .tls = error { return finish(.rejected, error.localizedDescription) }
        finish(wasReady ? .ended : .unreachable, error.localizedDescription)
    }

    private func finish(_ why: Close, _ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        if case .failed = connection.state {} else if connection.state != .cancelled { connection.cancel() }
        continuation.yield(.closed(why, reason: reason))
        continuation.finish()
    }
}
