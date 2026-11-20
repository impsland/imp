import Foundation
import ImpKit

/// What a Devices sheet can change while it is open, as it was when it opened. Switches act at once. Cancel puts
/// every one of them back. An Imp that was called home or a device that was forgotten stays so: those are actions.
@MainActor
struct DeviceEdits {
    private let hop: String
    private let limits: DeviceToolLimits
    private let trusted: [UUID: Bool]
    private let imps: [ImpProfile]

    init(_ model: AppModel) {
        hop = model.prefs.hop
        limits = model.prefs.deviceToolLimits
        trusted = Dictionary(model.link.peers.map { ($0.id, $0.isTrusted) }, uniquingKeysWith: { first, _ in first })
        imps = model.prefs.imps
    }

    func restore(_ model: AppModel) {
        if model.prefs.hop != hop { model.prefs.hop = hop }
        if model.prefs.deviceToolLimits != limits { model.prefs.deviceToolLimits = limits }
        for peer in model.link.peers where trusted[peer.id].map({ $0 != peer.isTrusted }) == true {
            model.link.setTrusted(peer.id, trusted[peer.id] ?? peer.isTrusted)
        }
        var prefs = model.prefs
        for before in imps {
            guard let index = prefs.imps.firstIndex(where: { $0.id == before.id }) else { continue }
            var back = before
            back.awayOn = prefs.imps[index].awayOn
            prefs.imps[index] = back
        }
        if prefs != model.prefs { model.changeByPerson(prefs) }
    }
}
