import Foundation
import ImpCore

/// The Den a person chose: the gallery and accounts, reached over HTTP or HTTPS. The core checks
/// the address (`servers_check_den`), so every app gives the same answer. Empty text is no Den.
public struct DenServer: Equatable, Sendable {
    /// The Den's base address, such as `https://den.example.com`, with no path.
    public let url: URL

    public init?(_ text: String) {
        let check = serversCheckDen(text: text)
        guard check.message == nil, let url = URL(string: check.address), !check.address.isEmpty else { return nil }
        self.url = url
    }
}

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

/// The two services a person can point Imp at, each on its own.
public enum ServerKind: Sendable {
    case den, hop

    /// The sentence that says why `text` is not an address, or nil when it is fine (or empty).
    public func problem(with text: String) -> String? {
        switch self {
        case .den: serversCheckDen(text: text).message
        case .hop: serversCheckHop(text: text).message
        }
    }

    /// The address Imp's own server has, and the one `imp serve` has on this computer.
    public var defaultAddress: String { self == .den ? serversDefaults().den : serversDefaults().hop }
    public var localAddress: String { self == .den ? serversDefaults().localDen : serversDefaults().localHop }
}

/// The choices next to an address field. `custom` is any other address, and `off` is empty.
public enum ServerChoice: CaseIterable, Sendable {
    case imps, thisComputer, custom, off

    /// The choice that an address stands for.
    public static func of(_ text: String, _ kind: ServerKind) -> ServerChoice {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .off }
        if text == kind.defaultAddress { return .imps }
        if text == kind.localAddress { return .thisComputer }
        return .custom
    }

    /// The address this choice fills in. Nil for `custom`, which the person types.
    public func address(_ kind: ServerKind) -> String? {
        switch self {
        case .imps: kind.defaultAddress
        case .thisComputer: kind.localAddress
        case .off: ""
        case .custom: nil
        }
    }
}

/// Which of the two services are set up. Each is independent: a person can have either, both or
/// neither, and the screens that need the missing one say so.
public struct ServerSetup: Equatable, Sendable {
    public let den: DenServer?
    public let hop: HopServer?

    /// From what is typed (or stored) for each. Text that is not a valid address counts as no server.
    public init(den: String, hop: String) {
        self.den = DenServer(den)
        self.hop = HopServer(hop)
    }
}

/// Where the iPhone keeps the two addresses: one key each, so either can change alone. Until the
/// person sets one, it is Imp's own server. Empty text is "off".
public struct ServerStore: Sendable {
    public static let denKey = "denAddress"
    public static let hopKey = "hopAddress"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var den: String {
        get { defaults.string(forKey: Self.denKey) ?? ServerKind.den.defaultAddress }
        nonmutating set { defaults.set(newValue, forKey: Self.denKey) }
    }
    public var hop: String {
        get { defaults.string(forKey: Self.hopKey) ?? ServerKind.hop.defaultAddress }
        nonmutating set { defaults.set(newValue, forKey: Self.hopKey) }
    }
}
