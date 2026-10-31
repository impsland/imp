import Foundation
import Network

/// A host's side of the Hop: keeps one connection waiting at the relay for a guest. When a guest
/// is spliced in, the bytes go straight on to this device's own Link listener on loopback, so TLS
/// ends in the same place, with the same key, as it does on Wi-Fi. Then it dials the next waiting one.
public final class HopHost: @unchecked Sendable {   // mutable state is only touched on `queue`
    private let address: HopAddress
    private let credentials: Hop.Credentials
    private let loopbackPort: UInt16
    private let queue = DispatchQueue(label: "app.imp.hop.host")
    private var running = false
    private var waiting: NWConnection?
    private var dialed = Date.distantPast
    private var delay: TimeInterval = 1
    private var redial: DispatchWorkItem?
    private var splices: [ObjectIdentifier: Splice] = [:]
    private var greeted = false

    /// How long the relay may take to answer the hello, how long a host waits at the relay (see
    /// `server/PROTOCOL.md`) and how much longer than that we allow, and how many guests are spliced at once.
    static let handshakeLimit: TimeInterval = 10
    static let hostWait: TimeInterval = 5 * 60
    static let slack: TimeInterval = 60
    static let maxSplices = 32

    /// The relay turned this host away (it won't be tried again until restarted).
    public var onRejected: (@Sendable () -> Void)?

    public init(address: HopAddress, credentials: Hop.Credentials, loopbackPort: UInt16) {
        self.address = address
        self.credentials = credentials
        self.loopbackPort = loopbackPort
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            dial()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            redial?.cancel()
            waiting?.cancel()
            waiting = nil
            splices.values.forEach { $0.end() }
        }
    }

    /// The network changed: forget the back-off and wait again right away.
    public func retryNow() {
        queue.async { [self] in
            guard running else { return }
            delay = 1
            redial?.cancel()
            waiting?.cancel()
            waiting = nil
            dial()
        }
    }

    // MARK: Waiting

    private func dial() {
        guard running, waiting == nil, let port = NWEndpoint.Port(rawValue: address.port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .tcp)
        waiting = c
        dialed = Date()
        greeted = false
        // A connection that never gets through the hello, or that waits for far longer than the relay
        // says it will, is given up on.
        queue.asyncAfter(deadline: .now() + Self.handshakeLimit) { [weak self, weak c] in
            guard let self, let c, c === self.waiting, !self.greeted else { return }
            self.lost(c)
        }
        queue.asyncAfter(deadline: .now() + Self.hostWait + Self.slack) { [weak self, weak c] in
            guard let self, let c, c === self.waiting else { return }
            self.lost(c)
        }
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready: self.greet(c)
            case .failed, .waiting: self.lost(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// Hello, then the proof for the relay's nonce, then its answer.
    private func greet(_ c: NWConnection) {
        c.send(content: credentials.hello, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.lost(c) }
        })
        Self.read(Hop.nonceBytes, from: c) { [weak self] nonce in
            guard let self, c === self.waiting else { return }
            guard let nonce, let proof = try? self.credentials.proof(nonce: nonce) else { return self.lost(c) }
            self.greeted = true
            c.send(content: proof, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.lost(c) }
            })
            Self.read(1, from: c) { [weak self] byte in
                guard let self, c === self.waiting else { return }
                guard let raw = byte?.first, let status = Hop.Status(rawValue: raw) else { return self.lost(c) }
                self.answered(c, status)
            }
        }
    }

    private func answered(_ c: NWConnection, _ status: Hop.Status) {
        switch status {
        case .go:
            // Too many guests at once, or no way to reach our own listener: let this one go.
            guard splices.count < Self.maxSplices, let splice = Splice(hop: c, loopbackPort: loopbackPort, queue: queue) else {
                return lost(c)
            }
            delay = 1
            waiting = nil
            c.stateUpdateHandler = nil
            let id = ObjectIdentifier(splice)
            splices[id] = splice
            splice.onEnd = { [weak self] in self?.splices[id] = nil }
            splice.start()
            dial()
        case .nobody:
            // The wait ran out. Wait again at once, unless it ended suspiciously fast.
            guard Date().timeIntervalSince(dialed) >= 1 else { return lost(c) }
            delay = 1
            c.cancel()
            waiting = nil
            dial()
        case .busy:
            lost(c)
        case .rejected:
            c.cancel()
            waiting = nil
            running = false
            onRejected?()
        }
    }

    /// The waiting connection failed: try again, a little later each time.
    private func lost(_ c: NWConnection) {
        guard c === waiting else { return }
        c.cancel()
        waiting = nil
        let wait = delay
        delay = min(delay * 2, 60)
        redial?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dial() }
        redial = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private static func read(_ count: Int, from c: NWConnection, _ done: @escaping @Sendable (Data?) -> Void) {
        c.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            done(error == nil && data?.count == count ? data : nil)
        }
    }

    // MARK: Passing bytes on

    /// One guest's connection from the relay, joined to this device's Link listener. Each chunk is
    /// read only after the last was handed on, so a slow side slows the other down.
    private final class Splice: @unchecked Sendable {
        private let hop: NWConnection
        private let local: NWConnection
        private let queue: DispatchQueue
        private var ended = false
        var onEnd: (() -> Void)?

        init?(hop: NWConnection, loopbackPort: UInt16, queue: DispatchQueue) {
            guard let port = NWEndpoint.Port(rawValue: loopbackPort) else { return nil }
            self.hop = hop
            self.local = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            self.queue = queue
        }

        func start() {
            local.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    pump(hop, to: local)
                    pump(local, to: hop)
                case .failed, .waiting, .cancelled: end()
                default: break
                }
            }
            local.start(queue: queue)
        }

        private func pump(_ from: NWConnection, to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
                guard !ended, error == nil else { return end() }
                guard let data, !data.isEmpty else { return complete ? end() : pump(from, to: to) }
                to.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil || complete { end() } else { pump(from, to: to) }
                })
            }
        }

        func end() {
            guard !ended else { return }
            ended = true
            local.stateUpdateHandler = nil
            hop.cancel()
            local.cancel()
            onEnd?()
            onEnd = nil
        }
    }
}
