import Foundation
import ImpCore

/// The Hop a person chose: the relay that lets devices reach each other from anywhere, as
/// `host:port`. The core checks the address (`servers_check_hop`). Empty text is no Hop.
public struct HopServer: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init?(_ text: String) {
        let check = serversCheckHop(text: text)
        guard check.message == nil, let colon = check.address.lastIndex(of: ":"),
              let port = UInt16(check.address[check.address.index(after: colon)...]) else { return nil }
        host = String(check.address[..<colon])
        self.port = port
    }

    /// The Hop as the link and a pairing code write it: `host:port`.
    public var address: String { "\(host):\(port)" }
}

/// The service a person can point Imp at.
public enum ServerKind: Sendable {
    case hop

    /// The sentence that says why `text` is not an address, or nil when it is fine (or empty).
    public func problem(with text: String) -> String? {
        serversCheckHop(text: text).message
    }

    /// The address Imp's own server has, and the one `imp serve` has on this computer (typed under Custom).
    public var defaultAddress: String { serversDefaults().hop }
    public var localAddress: String { serversDefaults().localHop }

    /// Whether `text` is a server on this very device (`localhost`, `127.x`): one the person runs here.
    public static func isOnThisDevice(_ text: String) -> Bool {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { $0 != ":" && $0 != "/" })
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.")
    }
}

/// The choices next to an address field. `custom` is any other address (a server of one's own, on this
/// computer too), and `off` is empty.
public enum ServerChoice: CaseIterable, Sendable {
    case imps, custom, off

    /// The choice that an address stands for.
    public static func of(_ text: String, _ kind: ServerKind) -> ServerChoice {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .off }
        if text == kind.defaultAddress { return .imps }
        return .custom
    }

    /// The address this choice fills in. Nil for `custom`, which the person types.
    public func address(_ kind: ServerKind) -> String? {
        switch self {
        case .imps: kind.defaultAddress
        case .off: ""
        case .custom: nil
        }
    }
}

/// Whether the Hop is set up.
public struct ServerSetup: Equatable, Sendable {
    public let hop: HopServer?

    /// From what is typed (or stored). Text that is not a valid address counts as no server.
    public init(hop: String) {
        self.hop = HopServer(hop)
    }
}

/// Where the iPhone keeps the Hop address. Until the
/// person sets one, it is Imp's own server. Empty text is "off".
public struct ServerStore: Sendable {
    public static let hopKey = "hopAddress"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hop: String {
        get { defaults.string(forKey: Self.hopKey) ?? ServerKind.hop.defaultAddress }
        nonmutating set { defaults.set(newValue, forKey: Self.hopKey) }
    }
}
