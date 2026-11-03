import CryptoKit
import Foundation
import Network
import Security

/// Everything cryptographic in Imp Link 2 (see `docs/LINK.md`): the keys derived from a door key,
/// the TLS settings, the proofs that tie a handshake to its own connection, and tickets.
public enum LinkCrypto {
    public static let keyBytes = 32

    // MARK: Keys

    /// 32 random bytes: a door key, an invite key, a ticket.
    public static func randomKey() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<keyBytes).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    /// The TLS pre-shared key: derived from the door key, never the door key itself.
    public static func psk(door: Data) -> Data {
        mac("imp-link psk v2", key: door)
    }

    /// The identity the pre-shared key goes by.
    public static let pskIdentity = Data("imp-link/2".utf8)

    /// The public half of the guests' key at the Hop (the host vouches for it, guests sign with it).
    public static func gate(door: Data) -> Data {
        Hop.gate(door: door).publicKey.rawRepresentation
    }

    private static func mac(_ text: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }

    // MARK: TLS

    /// Network settings for a link connection: TCP with keepalive, wrapped in TLS 1.2 with
    /// `ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`. The pre-shared key keeps strangers out; the
    /// ephemeral key exchange gives forward secrecy. With `hop`, the connection first goes
    /// through the Hop's handshake (below TLS), then runs the very same TLS end to end.
    public static func parameters(door: Data, hop: HopPass? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = psk(door: door).withUnsafeBytes { DispatchData(bytes: $0) }
        let id = pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, id as __DispatchData)
        // ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (0xCCAC).
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        if let hop {
            let framer = NWProtocolFramer.Options(definition: HopFramer.definition)
            framer[HopFramer.key] = hop
            params.defaultProtocolStack.applicationProtocols.append(framer)
        }
        return params
    }

    // MARK: Binding

    static let exporterLabel = "EXPORTER-imp-link/2"

    /// A 32-byte value both ends of this TLS session derive and nobody else can: what every proof
    /// signs or MACs, so a proof is only good on the connection it was made on.
    public static func binding(of connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let secret = sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, exporterLabel.utf8.count, exporterLabel, keyBytes)
        else { return nil }
        let data = Data(secret as DispatchData)
        return data.count == keyBytes ? data : nil
    }

    // MARK: Proofs

    /// What a guest signs in `hello`: the connection and who it is talking to.
    public static func helloMessage(binding: Data, host: UUID) -> Data {
        Data("imp-link/2 hello".utf8) + binding + uuidBytes(host)
    }

    /// What a host signs in `welcome`: the connection and who it is talking to.
    public static func welcomeMessage(binding: Data, guest: UUID) -> Data {
        Data("imp-link/2 welcome".utf8) + binding + uuidBytes(guest)
    }

    /// The guest's proof that it holds a fresh invite, good on this connection only.
    public static func joinProof(invite: Data, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("imp-link/2 join".utf8) + binding, using: SymmetricKey(data: invite)))
    }

    /// Whether `proof` is the join proof for `invite` on this connection (compared in constant time).
    public static func isValidJoin(_ proof: Data, invite: Data, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("imp-link/2 join".utf8) + binding, using: SymmetricKey(data: invite))
    }

    static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    // MARK: Tickets

    public static func mintTicket() -> Data { randomKey() }

    /// What the home keeps of a ticket, so a stolen book doesn't hold working tickets.
    public static func hash(ticket: Data) -> Data {
        Data(SHA256.hash(data: Data("imp-link/2 ticket".utf8) + ticket))
    }

    /// Whether `ticket` is the one `hash` stands for (constant time).
    public static func matches(ticket: Data, hash: Data) -> Bool {
        equal(self.hash(ticket: ticket), hash)
    }

    /// Compares secrets without stopping at the first difference.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
