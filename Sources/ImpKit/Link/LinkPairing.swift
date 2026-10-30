import CryptoKit
import Foundation

/// What an iPhone needs to reach a Mac and prove it was let in: the Mac's identity and name, a
/// 256-bit secret, and addresses to try besides Bonjour. The Mac shows it as a QR code
/// (`implink://pair?…`); the iPhone's camera opens it in Imp. The secret itself never crosses
/// the network: both sides derive the TLS pre-shared key from it (`psk`), so only a phone that
/// scanned the code can connect, and everything after is encrypted.
public struct LinkPairing: Equatable, Sendable, Codable {
    public var mac: UUID
    public var name: String
    public var secret: Data
    /// Host names or addresses to try when Bonjour can't see the Mac (another network, a VPN).
    public var hosts: [String]
    public var port: UInt16

    public static let scheme = "implink"
    public static let secretBytes = 32

    public init(mac: UUID, name: String, secret: Data, hosts: [String] = [], port: UInt16 = LinkProtocol.port) {
        self.mac = mac; self.name = name; self.secret = secret; self.hosts = hosts; self.port = port
    }

    /// A fresh random secret.
    public static func newSecret() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<secretBytes).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    /// The TLS pre-shared key: derived from the secret, never the secret itself.
    public var psk: Data { Self.psk(for: secret) }

    public static func psk(for secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("imp-link psk v1".utf8), using: SymmetricKey(data: secret)))
    }

    /// The link the QR code holds.
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        var items = [URLQueryItem(name: "v", value: String(LinkProtocol.version)),
                     URLQueryItem(name: "mac", value: mac.uuidString),
                     URLQueryItem(name: "name", value: name),
                     URLQueryItem(name: "key", value: Self.base64URL(secret))]
        if !hosts.isEmpty { items.append(URLQueryItem(name: "host", value: hosts.joined(separator: ","))) }
        if port != LinkProtocol.port { items.append(URLQueryItem(name: "port", value: String(port))) }
        c.queryItems = items
        return c.url!
    }

    /// Reads a pairing link. Nil unless it's whole: a Mac, a name and a full-length secret.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let mac = value("mac").flatMap(UUID.init(uuidString:)),
              let key = value("key").flatMap(Self.data(base64URL:)), key.count == Self.secretBytes else { return nil }
        let name = value("name").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let hosts = (value("host") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let port = value("port").flatMap(UInt16.init) ?? LinkProtocol.port
        self.init(mac: mac, name: name.isEmpty ? "Mac" : String(name.prefix(80)), secret: key, hosts: hosts, port: port)
    }

    /// Reads a pairing link pasted as text (whitespace around it is fine).
    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
