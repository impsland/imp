import CryptoKit
import Foundation

/// The Hop: a blind relay that lets two devices reach each other from anywhere (see
/// `server/PROTOCOL.md`). A host waits in a room named by its own public key; a guest joins by
/// proving it knows the host's door key. The relay splices the two streams, and what flows after
/// that is the Link's own TLS, end to end, so the relay only ever sees encrypted bytes.
public enum Hop {
    public enum Role: UInt8, Sendable {
        /// Owns the room and waits in it.
        case host = 1
        /// Joins the room.
        case guest = 2
    }

    /// The relay's answer once the proof was checked.
    public enum Status: UInt8, Sendable {
        /// The other side is spliced in: start TLS.
        case go = 0
        /// Bad hello or proof: give up on the Hop for now.
        case rejected = 1
        /// A limit was hit: back off.
        case busy = 2
        /// Nobody came before the wait ran out, or nobody is waiting.
        case nobody = 3
    }

    static let version: UInt8 = 2
    static let magic = Data("IMPHOP".utf8)
    static let proofTag = Data("imp-hop/2".utf8)
    static let gateTag = Data("imp-hop gate v2".utf8)
    public static let keyBytes = 32
    public static let nonceBytes = 32
    public static let proofBytes = 64
    public static let helloBytes = 6 + 2 + 32 + 32

    /// What one side needs to speak to the relay: the room, the gate and a way to sign.
    public struct Credentials: Sendable {
        public let role: Role
        /// The host's device public key: how the relay names the room.
        public let room: Data
        /// The public half of the key every guest derives from the door key.
        public let gate: Data
        private let signer: @Sendable (Data) throws -> Data

        /// The host: signs with its device key.
        public init(host identity: LinkIdentity, door: Data) {
            role = .host
            room = identity.publicKey
            gate = Hop.gate(door: door).publicKey.rawRepresentation
            signer = { identity.sign($0) }
        }

        /// A guest of `room`: signs with the gate key derived from the host's door key.
        public init(guestOf room: Data, door: Data) {
            let key = Hop.gate(door: door)
            role = .guest
            self.room = room
            gate = key.publicKey.rawRepresentation
            signer = { try key.signature(for: $0) }
        }

        /// First message to the relay: "IMPHOP", the version, the role, the room and the gate (72 bytes).
        public var hello: Data {
            Hop.magic + [Hop.version, role.rawValue] + room + gate
        }

        /// The signature the relay checks (64 bytes).
        public func proof(nonce: Data) throws -> Data {
            try signer(Hop.proofMessage(role: role, nonce: nonce, room: room, gate: gate))
        }
    }

    /// What gets signed to answer the relay's nonce: a host vouches for the gate, a guest for the room.
    public static func proofMessage(role: Role, nonce: Data, room: Data, gate: Data) -> Data {
        proofTag + [role.rawValue] + nonce + (role == .host ? gate : room)
    }

    /// The guests' key, the same for everyone who knows the door key.
    static func gate(door: Data) -> Curve25519.Signing.PrivateKey {
        let seed = Data(HMAC<SHA256>.authenticationCode(for: gateTag, using: SymmetricKey(data: door)))
        // A 32-byte seed always makes a key.
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

/// Where a Hop is: a host name and a port, written `host:port`.
public struct HopAddress: Equatable, Sendable {
    public static let longest = 255

    public let host: String
    public let port: UInt16

    public init?(host: String, port: UInt16) {
        let host = host.lowercased()
        guard port > 0, Self.isHost(host) else { return nil }
        self.host = host
        self.port = port
    }

    public init?(_ text: String) {
        guard text.utf8.count <= Self.longest, let colon = text.lastIndex(of: ":") else { return nil }
        let digits = text[text.index(after: colon)...]
        guard !digits.isEmpty, digits.utf8.count <= 5, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let port = UInt16(digits) else { return nil }
        self.init(host: String(text[..<colon]), port: port)
    }

    public var text: String { "\(host):\(port)" }

    /// Whether `host` is a plain lower-case host name or IPv4 address.
    static func isHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return host.utf8.count <= longest
            && !labels.isEmpty && labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
            && host.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E })
    }
}
