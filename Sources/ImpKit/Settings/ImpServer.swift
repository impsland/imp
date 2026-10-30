import Foundation

/// Where an Imp server lives. One host runs both halves: the Den (the gallery and accounts, over
/// HTTPS) and the Hop (the relay that lets an iPhone reach its Mac from anywhere, on `hopPort`).
///
/// Written as a host name (`imp.example.org`), an `https` address, or `http://localhost:<port>`
/// (plain HTTP only for this Mac, to try a server out).
public struct ImpServer: Equatable, Sendable {
    public static let hopPort: UInt16 = 4677

    /// The Den's base address, such as `https://imp.example.org`.
    public let den: URL
    /// The Hop's host and port.
    public let hopHost: String
    public let hopPort: UInt16

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var c = URLComponents(string: withScheme), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        c.scheme = scheme
        c.host = host
        c.path = ""
        guard let url = c.url else { return nil }
        den = url
        hopHost = host
        hopPort = Self.hopPort
    }

    /// The Hop as written in a pairing link: `host:port`.
    public var hop: String { "\(hopHost):\(hopPort)" }
}
