import Foundation
import Network

/// One plain TCP connection. The core does the handshake and the encryption, so this only moves bytes.
public final class LinkSocket: @unchecked Sendable {   // NWConnection is thread safe
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
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
    }

    /// Waits until everything sent so far has left. False if the connection is gone.
    public func drained() async -> Bool {
        await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                finished.resume(returning: error == nil)
            })
        }
    }

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
