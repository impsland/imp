import Foundation
import Network

/// What a connection through the Hop carries: the room to join, and what the relay answered.
public final class HopPass: @unchecked Sendable {
    let room: Hop.Room
    let role: Hop.Role
    private let lock = NSLock()
    private var answer: Hop.Status?

    public init(room: Hop.Room, role: Hop.Role) {
        self.room = room
        self.role = role
    }

    /// The relay's answer, once it gave one.
    public var status: Hop.Status? {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
}

/// Sits below TLS on a connection to the Hop: says hello, signs the relay's nonce, reads its
/// answer, and from then on lets every byte through untouched. TLS starts once the relay says go.
final class HopFramer: NWProtocolFramerImplementation {
    static let label = "imp-hop"
    static let key = "pass"
    static let definition = NWProtocolFramer.Definition(implementation: HopFramer.self)

    private enum Step { case nonce, status, through }
    private var step = Step.nonce

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let pass = framer.options[Self.key] as? HopPass else { return .willMarkReady }
        framer.writeOutput(data: pass.room.hello(as: pass.role))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard let pass = framer.options[Self.key] as? HopPass else {
            framer.markFailed(error: .posix(.EINVAL))
            return 0
        }
        while step != .through {
            switch step {
            case .nonce:
                guard let nonce = Self.read(Hop.nonceBytes, from: framer) else { return Hop.nonceBytes }
                guard let proof = try? pass.room.proof(as: pass.role, nonce: nonce) else {
                    framer.markFailed(error: .posix(.EINVAL))
                    return 0
                }
                framer.writeOutput(data: proof)
                step = .status
            case .status:
                guard let byte = Self.read(1, from: framer)?.first else { return 1 }
                let status = Hop.Status(rawValue: byte)
                pass.status = status
                guard status == .go else {
                    framer.markFailed(error: .posix(.ECONNREFUSED))
                    return 0
                }
                step = .through
                framer.markReady()
                framer.passThroughInput()
                framer.passThroughOutput()
            case .through:
                break
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    /// Exactly `count` bytes, or nil if they haven't all arrived.
    private static func read(_ count: Int, from framer: NWProtocolFramer.Instance) -> Data? {
        var out: Data?
        _ = framer.parseInput(minimumIncompleteLength: count, maximumLength: count) { buffer, _ in
            guard let buffer, buffer.count >= count else { return 0 }
            out = Data(buffer.prefix(count))
            return count
        }
        return out
    }
}
