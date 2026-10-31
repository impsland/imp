import CryptoKit
import Foundation

/// What kind of device this is.
public enum LinkKind: String, Codable, Sendable, Equatable {
    case mac, phone
}

/// Who a device says it is, as other devices know it. Public things only.
public struct LinkDevice: Codable, Sendable, Equatable, Identifiable {
    public static let longestName = 80

    public var id: UUID
    public var name: String
    public var kind: LinkKind
    /// The Ed25519 public key (32 bytes) other devices pin.
    public var key: Data

    public init(id: UUID, name: String, kind: LinkKind, key: Data) {
        self.id = id; self.name = Self.cleaned(name, kind: kind); self.kind = kind; self.key = key
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, key }

    /// Names are cleaned and a key must be whole, wherever the device came from.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(LinkKind.self, forKey: .kind)
        let key = try c.decode(Data.self, forKey: .key)
        guard key.count == LinkCrypto.keyBytes else { throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "bad key") }
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), kind: kind, key: key)
    }

    /// A name people recognise: trimmed, capped, never empty.
    public static func cleaned(_ name: String, kind: LinkKind) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (kind == .mac ? "Mac" : "iPhone") : String(trimmed.prefix(longestName))
    }
}

/// This device: its id, name and kind, and the signing key that never leaves it. Everything other
/// devices trust about it comes from signatures made with this key.
public struct LinkIdentity: Sendable, CustomStringConvertible {
    public let id: UUID
    public var name: String
    public let kind: LinkKind
    private let key: Curve25519.Signing.PrivateKey

    public init(id: UUID = UUID(), name: String, kind: LinkKind, key: Curve25519.Signing.PrivateKey = .init()) {
        self.id = id
        self.name = LinkDevice.cleaned(name, kind: kind)
        self.kind = kind
        self.key = key
    }

    /// Rebuilds an identity from the key's raw bytes (nil unless they're a whole key).
    public init?(id: UUID, name: String, kind: LinkKind, seed: Data) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        self.init(id: id, name: name, kind: kind, key: key)
    }

    /// The key's raw bytes, for the book. Never log them.
    var seed: Data { key.rawRepresentation }

    public var publicKey: Data { key.publicKey.rawRepresentation }

    public var device: LinkDevice { LinkDevice(id: id, name: name, kind: kind, key: publicKey) }

    /// A signature (64 bytes) over `message`.
    public func sign(_ message: Data) -> Data {
        // Signing with a valid key only fails if the system can't make random numbers.
        try! key.signature(for: message)
    }

    /// Whether `signature` is `key`'s over `message`. False for a key that isn't one.
    public static func verify(_ signature: Data, of message: Data, key: Data) -> Bool {
        guard signature.count == Hop.proofBytes, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    public var description: String { "LinkIdentity(\(id), \(name), \(kind.rawValue))" }
}
