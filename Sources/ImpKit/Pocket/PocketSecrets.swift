import Foundation

/// A secret a pocket Imp keeps: its service's API key, or the value of a tool server's header.
public enum PocketSlot: Hashable, Sendable {
    case apiKey
    /// The header value of one of its servers (`PocketServer.id`).
    case header(UUID)

    /// A stable name for the slot, for a Keychain account: `pocket.<imp>.apiKey` or `pocket.<imp>.header.<server>`.
    public func account(imp: UUID) -> String {
        switch self {
        case .apiKey: "pocket.\(imp.uuidString).apiKey"
        case .header(let server): "pocket.\(imp.uuidString).header.\(server.uuidString)"
        }
    }
}

/// Where a pocket Imp's secrets are kept. The iPhone app implements it with the Keychain. Nothing
/// secret is ever in a `PocketImp`, in its chats or in the kit that moves it to the Mac.
public protocol PocketSecrets: Sendable {
    func get(_ slot: PocketSlot, imp: UUID) -> String?
    func set(_ value: String, _ slot: PocketSlot, imp: UUID)
    func remove(_ slot: PocketSlot, imp: UUID)
}

extension PocketSecrets {
    /// Forgets every secret of an Imp (it moved home or was removed).
    public func removeAll(of imp: PocketImp) {
        remove(.apiKey, imp: imp.id)
        for server in imp.servers { remove(.header(server.id), imp: imp.id) }
    }
}
