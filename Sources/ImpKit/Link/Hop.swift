import CryptoKit
import Foundation

/// The Hop: a blind relay that lets an iPhone reach its Mac from anywhere (see `server/PROTOCOL.md`).
/// Both sides dial the relay, prove they know the pairing secret by signing a nonce, and the relay
/// splices their two streams. What flows after that is the Link's own TLS, end to end, so the relay
/// only ever sees encrypted bytes.
public enum Hop {
    public enum Role: UInt8, Sendable {
        /// Hosts the room and waits.
        case mac = 1
        /// Joins it.
        case phone = 2
    }

    /// The relay's answer once the proof was checked.
    public enum Status: UInt8, Sendable {
        /// The other side is spliced in: start TLS.
        case go = 0
        /// Bad hello or proof: give up on the Hop for this pairing.
        case rejected = 1
        /// A limit was hit: back off.
        case busy = 2
        /// Nobody came before the wait ran out.
        case nobody = 3
    }

    static let version: UInt8 = 1
    static let magic = Data("IMPHOP".utf8)
    static let proofTag = Data("imp-hop/1".utf8)
    static let roomTag = Data("imp-hop room v1".utf8)
    public static let nonceBytes = 32
    public static let proofBytes = 64

    /// A pairing's room: an Ed25519 key pair both sides derive from the pairing secret. Its public
    /// half names the room at the relay, and only someone holding the secret can sign for it.
    public struct Room: Sendable {
        private let key: Curve25519.Signing.PrivateKey

        public init(secret: Data) {
            let seed = Data(HMAC<SHA256>.authenticationCode(for: Hop.roomTag, using: SymmetricKey(data: secret)))
            // A 32-byte seed always makes a key.
            key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        }

        /// The room's public key: how the relay knows it.
        public var id: Data { key.publicKey.rawRepresentation }

        /// First message to the relay: "IMPHOP", the version, the role and the room (40 bytes).
        public func hello(as role: Role) -> Data {
            Hop.magic + [Hop.version, role.rawValue] + id
        }

        /// What gets signed to answer the relay's nonce.
        public static func proofMessage(as role: Role, nonce: Data) -> Data {
            Hop.proofTag + [role.rawValue] + nonce
        }

        /// The signature the relay checks against the room (64 bytes).
        public func proof(as role: Role, nonce: Data) throws -> Data {
            try key.signature(for: Self.proofMessage(as: role, nonce: nonce))
        }
    }
}

/// Where a Hop is: a host name and a port, written `host:port`.
public struct HopAddress: Equatable, Sendable {
    public static let longest = 255

    public let host: String
    public let port: UInt16

    public init?(host: String, port: UInt16) {
        let host = host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard port > 0, host.utf8.count <= Self.longest,
              !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              host.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E })
        else { return nil }
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
}
