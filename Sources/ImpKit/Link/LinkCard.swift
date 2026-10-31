import Foundation

/// Where else a device can be reached besides Bonjour: host names or addresses on a network the
/// other side shares or can route to (Wi-Fi, a VPN), the port, and the Hop it waits at. Checked
/// when it is built or read, so what's held is always dialable text.
public struct LinkRoutes: Codable, Sendable, Equatable {
    public static let mostHosts = 8

    public var hosts: [String]
    public var port: UInt16
    /// The Hop this device waits at (`host:port`), nil if it has no server.
    public var hop: String?

    public static let none = LinkRoutes(hosts: [])

    /// Nil unless every piece is valid. Hosts are lower-cased and de-duplicated.
    public init?(checking hosts: [String], port: UInt16, hop: String?) {
        var seen = Set<String>()
        let hosts = hosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { seen.insert($0).inserted }
        guard port > 0, hosts.count <= Self.mostHosts, hosts.allSatisfy(HopAddress.isHost) else { return nil }
        var hopText: String?
        if let hop {
            guard let address = HopAddress(hop) else { return nil }
            hopText = address.text
        }
        self.hosts = hosts; self.port = port; self.hop = hopText
    }

    /// Keeps what's valid of `hosts` (up to the most there can be), for routes this device builds itself.
    public init(hosts: [String], port: UInt16 = LinkProtocol.port, hop: String? = nil) {
        var seen = Set<String>()
        self.hosts = Array(hosts.map { $0.lowercased() }.filter { HopAddress.isHost($0) && seen.insert($0).inserted }.prefix(Self.mostHosts))
        self.port = port > 0 ? port : LinkProtocol.port
        self.hop = hop.flatMap(HopAddress.init)?.text
    }

    private enum CodingKeys: String, CodingKey { case hosts, port, hop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let checked = LinkRoutes(checking: try c.decode([String].self, forKey: .hosts), port: try c.decode(UInt16.self, forKey: .port),
                                       hop: try c.decodeIfPresent(String.self, forKey: .hop)) else {
            throw DecodingError.dataCorruptedError(forKey: .hosts, in: c, debugDescription: "bad routes")
        }
        self = checked
    }

    public var hopAddress: HopAddress? { hop.flatMap(HopAddress.init) }
}

/// A device's visiting card: who it is and how to reach it. An Imp carries its home's card when it
/// travels, so whoever holds it can find its home again, even without a link to it. It has the home's
/// door key, so a card is a secret: never log it.
public struct LinkCard: Codable, Sendable, Equatable {
    public var device: LinkDevice
    public var door: Data
    public var routes: LinkRoutes

    public init(device: LinkDevice, door: Data, routes: LinkRoutes) {
        self.device = device; self.door = door; self.routes = routes
    }

    public var id: UUID { device.id }

    private enum CodingKeys: String, CodingKey { case device, door, routes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(LinkDevice.self, forKey: .device)
        door = try c.decode(Data.self, forKey: .door)
        routes = try c.decode(LinkRoutes.self, forKey: .routes)
        guard door.count == LinkCrypto.keyBytes else { throw DecodingError.dataCorruptedError(forKey: .door, in: c, debugDescription: "bad door") }
    }
}
