import Foundation

/// A secret a pocket Imp keeps: its service's API key, or the value of a tool server's header.
public enum PocketSlot: Hashable, Sendable {
    case apiKey
    /// The value of one header of one of its servers (`PocketServer.id`, the header's name).
    case header(UUID, String)

    /// A stable name for the slot, for a Keychain account: `pocket.<imp>.apiKey` or `pocket.<imp>.header.<server>.<name in lower case>`.
    public func account(imp: UUID) -> String {
        switch self {
        case .apiKey: "pocket.\(imp.uuidString).apiKey"
        case .header(let server, let name): "pocket.\(imp.uuidString).header.\(server.uuidString).\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }
}

/// Where a pocket Imp's secrets are kept. The iPhone app implements it with the Keychain. Nothing
/// secret is ever in a `PocketImp`, in its chats or in the kit that moves it to the Mac.
public protocol PocketSecrets: Sendable {
    func get(_ slot: PocketSlot, imp: UUID) -> String?
    /// Keeps a secret. Throws if it couldn't be kept (the Keychain refused).
    func set(_ value: String, _ slot: PocketSlot, imp: UUID) throws
    func remove(_ slot: PocketSlot, imp: UUID)
}

extension PocketSecrets {
    /// Forgets every secret of an Imp (it moved home or was removed).
    public func removeAll(of imp: PocketImp) {
        remove(.apiKey, imp: imp.id)
        for server in imp.servers { removeHeaders(of: server, imp: imp.id) }
    }

    /// Forgets every header value of a server.
    public func removeHeaders(of server: PocketServer, imp: UUID) {
        for name in server.headers { remove(.header(server.id, name), imp: imp) }
    }

    /// The header values of a server by name, those that have one.
    public func headerValues(of server: PocketServer, imp: UUID) -> [String: String] {
        var values: [String: String] = [:]
        for name in server.headers {
            if let value = get(.header(server.id, name), imp: imp), !value.isEmpty { values[name] = value }
        }
        return values
    }
}
