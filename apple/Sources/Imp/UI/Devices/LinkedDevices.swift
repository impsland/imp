import Foundation
import ImpKit

/// What the device list says, worked out from the link alone (tested in `ImpTests`).
enum LinkedDevices {
    /// A to Z by name.
    static func sorted(_ peers: [DeviceLink.Peer]) -> [DeviceLink.Peer] {
        peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func symbol(_ kind: LinkKind) -> String { kind == .mac ? "desktopcomputer" : "iphone.gen3" }

    /// The compact picture for how a device is reached: on the network, through the server, or away.
    static func reachSymbol(_ reach: DeviceLink.Peer.Reach) -> String {
        switch reach {
        case .direct: "wifi"
        case .viaServer: "arrow.triangle.swap"
        case .away: "moon.zzz.fill"
        }
    }

    /// How a device is reached, in words, and whether it is connected at all.
    static func reach(_ peer: DeviceLink.Peer, hop: HopServer?) -> (text: String, connected: Bool) {
        switch peer.reach {
        case .direct: (String(localized: "Connected on the local network"), true)
        case .viaServer: (hop.map { String(localized: "Connected through \($0.host)") } ?? String(localized: "Connected through the server"), true)
        case .away: (String(localized: "Away"), false)
        }
    }

    /// A device that linked since `before` (the ones there when the code came up).
    static func newcomer(_ peers: [DeviceLink.Peer], before: Set<UUID>) -> String? {
        peers.first { !before.contains($0.id) }?.name
    }
}
