import Foundation
import Network

/// One plain TCP connection. The core does the handshake and the encryption, so this only moves bytes.
public final class LinkSocket: @unchecked Sendable {   // NWConnection is thread safe; the rest is under `lock`
    let connection: NWConnection
    static let queue = DispatchQueue(label: "app.imp.link.socket")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public convenience init?(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        self.init(connection: NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp))
    }

    public convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .tcp))
    }

    /// Connects. False when it could not within `timeout` seconds (no route, refused, no answer).
    public func connect(timeout: TimeInterval = 8) async -> Bool {
        await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            let once = FirstCall()
            let end: @Sendable (Bool) -> Void = { ok in
                guard once.first() else { return }
                if !ok { self.cancel() }
                finished.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: end(true)
                case .failed, .waiting, .cancelled: end(false)
                default: break
                }
            }
            connection.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + timeout) { end(false) }
        }
    }

    /// Starts a connection that came in. Sends wait for it to be ready.
    func accept() {
        connection.start(queue: Self.queue)
    }

    /// The next bytes, or nil when the connection ended.
    public func read() async -> Data? {
        await withCheckedContinuation { (next: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty { next.resume(returning: data) } else if error != nil || complete { next.resume(returning: nil) } else { next.resume(returning: Data()) }
            }
        }
    }

    public func send(_ data: Data) {
        lock.withLock { sending += 1 }
        // Holds the socket until the bytes are processed, so whoever waits in `drained` is always answered.
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { self.cancel() }
            self.sent(ok: error == nil)
        })
    }

    /// Waits until everything sent so far has left. False if the connection is gone (or a send failed).
    ///
    /// Counted from the completions of the sends themselves. (It used to send an empty message and wait for
    /// that, which Network refuses with "invalid argument": every wait failed, and a file never went.)
    public func drained() async -> Bool {
        await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            let now: Bool? = lock.withLock {
                if broken { return false }
                if sending == 0 { return true }
                waiting.append(finished)
                return nil
            }
            if let now { finished.resume(returning: now) }
        }
    }

    /// One send is done: once none is left (or one failed), whoever waits is told.
    private func sent(ok: Bool) {
        let (answer, ready): (Bool, [CheckedContinuation<Bool, Never>]) = lock.withLock {
            sending -= 1
            if !ok { broken = true }
            guard sending == 0 || broken else { return (true, []) }
            defer { waiting = [] }
            return (!broken, waiting)
        }
        ready.forEach { $0.resume(returning: answer) }
    }

    // Sends not yet processed, whether one failed, and who waits for them: only touched under `lock`.
    private let lock = NSLock()
    private var sending = 0
    private var broken = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    public func cancel() {
        connection.cancel()
    }
}

/// Lets one caller through, once.
final class FirstCall: @unchecked Sendable {   // `done` is only touched under `lock`
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
