import Foundation
import ImpCore
import Network

/// The "Check" button of a server setting: whether the Hop answers at its address.
public enum ServerProbe {
    /// How long to wait before saying it cannot be reached.
    public static let timeout: TimeInterval = 6

    public static func reachable(_ kind: ServerKind, _ text: String) async -> Bool {
        switch kind {
        case .hop:
            guard let server = HopServer(text), let port = NWEndpoint.Port(rawValue: server.port) else { return false }
            return await connects(host: server.host, port: port)
        }
    }

    /// A plain connection opens: the Hop is listening there.
    private static func connects(host: String, port: NWEndpoint.Port) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true, connection)
                case .failed, .cancelled: once.finish(false, connection)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(false, connection) }
        }
    }

    /// Answers once, whichever of the connection and the timer comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func finish(_ value: Bool, _ connection: NWConnection) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            guard let c else { return }
            connection.cancel()
            c.resume(returning: value)
        }
    }
}
