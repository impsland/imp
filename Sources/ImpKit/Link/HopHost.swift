import Foundation
import Network

/// The Mac's side of the Hop: keeps one connection waiting at the relay for a phone. When a phone
/// is spliced in, the bytes go straight on to this Mac's own Link listener on loopback, so TLS ends
/// in the same place, with the same key, as it does on Wi-Fi. Then it dials the next waiting one.
public final class HopHost: @unchecked Sendable {   // mutable state is only touched on `queue`
    private let address: HopAddress
    private let room: Hop.Room
    private let loopbackPort: UInt16
    private let queue = DispatchQueue(label: "app.imp.hop.host")
    private var running = false
    private var waiting: NWConnection?
    private var dialed = Date.distantPast
    private var delay: TimeInterval = 1
    private var redial: DispatchWorkItem?
    private var splices: [ObjectIdentifier: Splice] = [:]

    /// The relay turned this pairing away (it won't be tried again until restarted).
    public var onRejected: (@Sendable () -> Void)?

    public init(address: HopAddress, room: Hop.Room, loopbackPort: UInt16) {
        self.address = address
        self.room = room
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

    // MARK: Waiting

    private func dial() {
        guard running, waiting == nil, let port = NWEndpoint.Port(rawValue: address.port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .tcp)
        waiting = c
        dialed = Date()
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
        c.send(content: room.hello(as: .mac), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.lost(c) }
        })
        Self.read(Hop.nonceBytes, from: c) { [weak self] nonce in
            guard let self, c === self.waiting else { return }
            guard let nonce, let proof = try? self.room.proof(as: .mac, nonce: nonce) else { return self.lost(c) }
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
            delay = 1
            waiting = nil
            c.stateUpdateHandler = nil
            let splice = Splice(hop: c, loopbackPort: loopbackPort, queue: queue)
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

    /// One phone's connection from the relay, joined to this Mac's Link listener. Each chunk is
    /// read only after the last was handed on, so a slow side slows the other down.
    private final class Splice: @unchecked Sendable {
        private let hop: NWConnection
        private let local: NWConnection
        private let queue: DispatchQueue
        private var ended = false
        var onEnd: (() -> Void)?

        init(hop: NWConnection, loopbackPort: UInt16, queue: DispatchQueue) {
            self.hop = hop
            self.local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: loopbackPort)!, using: .tcp)
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
