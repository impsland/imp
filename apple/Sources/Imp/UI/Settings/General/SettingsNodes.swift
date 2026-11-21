import ImpKit

/// The nodes of the app as it is now (this device, its Imps, services, The Den, The Hop and the other
/// devices). They are not drawn as a map. The "needs attention" marks and notices of the settings are
/// worked out from them.
@MainActor
enum SettingsNodes {
    /// The core's map of devices for the current link state, preferences and troupe.
    static func deviceMap(for model: AppModel) -> DeviceMap {
        let peers = model.link.peers.map { peer in
            DeviceMap.Peer(id: peer.id, name: peer.name, kind: peer.kind,
                           reach: { switch peer.reach { case .direct: .direct; case .viaServer: .viaServer; case .away: .away } }(),
                           isTrusted: peer.isTrusted, stage: peer.stage, routes: peer.routes)
        }
        // Where this Mac answers on the local network, once the listener has a port.
        let thisRoutes = model.link.status.flatMap { status in
            status.routes.port.map { LinkRoutes(hosts: status.routes.hosts, port: $0) }
        }
        return DeviceMap.build(thisMac: DeviceLink.deviceName, thisRoutes: thisRoutes, peers: peers,
                               server: HopServer(model.prefs.hop)?.address ?? "",
                               imps: model.prefs.imps, mcpServers: model.prefs.mcpServers, visitors: model.link.visitorsStaged, known: model.link.knownDevices)
    }

    /// The nodes for the app as it is now.
    static func nodes(for model: AppModel) -> [SettingsNode] {
        SettingsMap.nodes(prefs: model.prefs, map: deviceMap(for: model))
    }
}
