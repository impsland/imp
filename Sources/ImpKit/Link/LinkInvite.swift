import Foundation

/// What a device needs to join another and prove it was invited: the inviting device (the host),
/// its keys and addresses. The host shows it as a QR code (`implink://join?…`); the guest's camera
/// opens it in Imp. The door and invite keys never cross the network in the clear: the door key
/// opens the host's TLS and the invite key lets one device become a linked peer. Never log it.
public struct LinkInvite: Equatable, Sendable, CustomStringConvertible {
    public var device: LinkDevice
    /// Opens the host's TLS (`LinkCrypto.psk`). Stays the same until the host forgets everyone.
    public var door: Data
    /// Lets a guest become a linked peer. New every time the host shows a code.
    public var invite: Data
    public var routes: LinkRoutes

    public static let scheme = "implink"
    public static let version = 2

    public init(device: LinkDevice, door: Data, invite: Data, routes: LinkRoutes) {
        self.device = device; self.door = door; self.invite = invite; self.routes = routes
    }

    /// The host's visiting card, which is what a guest keeps of it.
    public var card: LinkCard { LinkCard(device: device, door: door, routes: routes) }

    /// The link the QR code holds.
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "join"
        var items = [URLQueryItem(name: "v", value: String(Self.version)),
                     URLQueryItem(name: "d", value: device.id.uuidString),
                     URLQueryItem(name: "n", value: device.name),
                     URLQueryItem(name: "t", value: device.kind.rawValue),
                     URLQueryItem(name: "k", value: Self.base64URL(device.key)),
                     URLQueryItem(name: "door", value: Self.base64URL(door)),
                     URLQueryItem(name: "inv", value: Self.base64URL(invite))]
        if !routes.hosts.isEmpty { items.append(URLQueryItem(name: "h", value: routes.hosts.joined(separator: ","))) }
        if routes.port != LinkProtocol.port { items.append(URLQueryItem(name: "p", value: String(routes.port))) }
        if let hop = routes.hop { items.append(URLQueryItem(name: "hop", value: hop)) }
        c.queryItems = items
        return c.url!
    }

    /// Reads an invite. Nil unless it's whole and every value is what it should be: a version we
    /// speak, an id, full-length keys in base64url, a short name, a few valid hosts, a port.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "join", url.absoluteString.utf8.count <= 2_000,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value else { return nil }
            // A repeated name is ambiguous: refuse rather than guess which one counts.
            guard values.updateValue(value, forKey: item.name) == nil else { return nil }
        }
        guard values["v"] == String(Self.version),
              let id = values["d"].flatMap(UUID.init(uuidString:)),
              let kind = values["t"].flatMap(LinkKind.init(rawValue:)),
              let key = values["k"].flatMap(Self.data(base64URL:)), key.count == LinkCrypto.keyBytes,
              let door = values["door"].flatMap(Self.data(base64URL:)), door.count == LinkCrypto.keyBytes,
              let invite = values["inv"].flatMap(Self.data(base64URL:)), invite.count == LinkCrypto.keyBytes else { return nil }
        let hosts = (values["h"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var port = LinkProtocol.port
        if let text = values["p"] {
            guard text.utf8.count <= 5, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let number = UInt16(text), number > 0 else { return nil }
            port = number
        }
        guard let routes = LinkRoutes(checking: values["h"] == nil ? [] : hosts, port: port, hop: values["hop"]) else { return nil }
        self.init(device: LinkDevice(id: id, name: values["n"] ?? "", kind: kind, key: key), door: door, invite: invite, routes: routes)
    }

    /// Reads an invite pasted as text (whitespace around it is fine).
    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    /// Keys stay out of logs and debug output.
    public var description: String { "LinkInvite(\(device.id), \(device.name))" }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only the base64url alphabet, no padding, and nothing a decoder would have to guess at.
    static func data(base64URL s: String) -> Data? {
        guard s.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }),
              s.utf8.count % 4 != 1 else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        // Only the one spelling a key has: no stray bits at the end.
        guard let data = Data(base64Encoded: b), base64URL(data) == s else { return nil }
        return data
    }
}
