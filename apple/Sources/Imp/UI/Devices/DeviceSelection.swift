import Foundation
import ImpKit

/// What a click on the Devices canvas opens a sheet about. Its identity is the thing itself, so one sheet is
/// open at a time and choosing another thing from inside a sheet swaps the sheet.
enum DeviceSelection: Hashable, Identifiable {
    case node(String)
    /// An Imp's chip: the Imp and the node it is in (an Imp can be seen on more than one screen).
    case imp(UUID, in: String)
    case channel(String)

    var id: Self { self }

    /// The selection as it still stands in `map`: nil once what was selected is gone (a forgotten device,
    /// an Imp that came home), so a sheet never describes something that isn't there.
    func resolved(in map: DeviceMap) -> DeviceSelection? {
        switch self {
        case .node(let id): map.node(id) == nil ? nil : self
        case .imp(let id, let node):
            map.residents(of: node).contains { $0.id == id } ? self : nil
        case .channel(let id): map.channels.contains { $0.id == id } ? self : nil
        }
    }
}

/// What the Devices screen can have open over it: a sheet about something on the canvas, the Hop's, or the Link a
/// device sheet. One at a time, so a sheet's button that leads to another swaps them.
enum DevicesSheet: Hashable, Identifiable {
    case about(DeviceSelection)
    /// The Hop is a setting, not a linked thing: its sheet does not depend on a node being in the map, so it stays
    /// open while its address is being chosen.
    case hop
    case link

    var id: Self { self }

    /// The sheet that opens `selection`: the Hop's node has its own sheet.
    static func opening(_ selection: DeviceSelection) -> DevicesSheet {
        selection == .node(DeviceMap.serverID) ? .hop : .about(selection)
    }

    /// The sheet as it still stands in `map`: one about something that is gone (a forgotten device, an Imp that
    /// came home) is nil and closes. The Hop's sheet never does: the Hop is a setting, not a linked thing.
    func resolved(in map: DeviceMap) -> DevicesSheet? {
        guard case .about(let selection) = self else { return self }
        return selection.resolved(in: map).map(DevicesSheet.about)
    }
}
