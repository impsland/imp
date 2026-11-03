import Foundation

/// A secret a pocket Imp keeps: its service's API key, or the value of a tool server's header.
public enum PocketSlot: Hashable, Sendable {
    case apiKey
    /// The value of one header of one of its servers (`PocketServer.id`, the header's name).
    case header(UUID, String)
    /// The one header value that Imps saved before servers had several headers kept (`PocketServer.id`).
    case legacyHeader(UUID)

    /// A stable name for the slot, for a Keychain account: `pocket.<imp>.apiKey` or `pocket.<imp>.header.<server>.<name in lower case>`.
    public func account(imp: UUID) -> String {
        switch self {
        case .apiKey: "pocket.\(imp.uuidString).apiKey"
        case .header(let server, let name): "pocket.\(imp.uuidString).header.\(server.uuidString).\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        case .legacyHeader(let server): "pocket.\(imp.uuidString).header.\(server.uuidString)"
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
        remove(.legacyHeader(server.id), imp: imp)
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

    /// Moves the one header value of the old shape to where several are kept, once. A value that
    /// can't be moved stays where it was and is tried again next time.
    public func migrateLegacyHeaders(of imp: PocketImp) {
        for server in imp.servers {
            guard let old = get(.legacyHeader(server.id), imp: imp.id) else { continue }
            if let name = server.headers.first, get(.header(server.id, name), imp: imp.id) == nil, !old.isEmpty {
                do { try set(old, .header(server.id, name), imp: imp.id) } catch { continue }
            }
            remove(.legacyHeader(server.id), imp: imp.id)
        }
    }
}
