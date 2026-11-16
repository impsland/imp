import Foundation
import ImpCore

/// The names `imp_message` takes for the Imps one Imp can message. Imps on different devices may share a
/// name (Pip on the Mac, Pip on the iPhone, Pip on the command line), so every name the tool takes is
/// different and none is the sender's own: `Pip@iPhone`, `Pip 2`. The rule is the core's
/// (`troupe::tool_names`), so the Mac, the iPhone and the command line name them alike.
public struct TalkNames<Here, Away> {
    /// The Imps of this device, by the name the tool takes.
    public let here: [(name: String, imp: Here)]
    /// The Imps on other devices, by the name the tool takes.
    public let away: [(name: String, imp: Away)]

    /// `here` are the Imps of this device and `away` the Imps elsewhere. `name` gives an Imp's own name,
    /// `place` the device an Imp elsewhere is on.
    public init(sender: String, here: [Here], name: (Here) -> String, away: [Away], awayName: (Away) -> String, place: (Away) -> String) {
        let names = ImpCore.troupeToolNames(sender: sender, here: here.map(name),
                                            away: away.map { ImpCore.TroupeAway(name: awayName($0), place: place($0)) })
        self.here = Array(zip(names.here, here)).map { (name: $0.0, imp: $0.1) }
        self.away = Array(zip(names.away, away)).map { (name: $0.0, imp: $0.1) }
    }

    /// Every name, the Imps here first.
    public var names: [String] { here.map(\.name) + away.map(\.name) }

    /// The Imp a name the model wrote stands for (ignoring case and spaces around it).
    public func find(_ name: String) -> (here: Here?, away: Away?) {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func same(_ label: String) -> Bool { label.caseInsensitiveCompare(wanted) == .orderedSame }
        if let hit = here.first(where: { same($0.name) }) { return (hit.imp, nil) }
        return (nil, away.first { same($0.name) }?.imp)
    }
}
