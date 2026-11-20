import ImpKit
import Testing
@testable import Imp

/// The plug board's layout and its reading of a device's access: even full-width rows, and a tool is only plugged
/// in while the device is trusted.
@MainActor
struct PlugBoardTests {
    private func item(_ id: String) -> PlugItem { PlugItem(id: id, symbol: "circle", title: id, plugged: false) }

    @Test func rowsAreBalancedAndNeverLeaveALoneLastPlug() {
        #expect(PlugBoard.rowLengths(1) == [1])
        #expect(PlugBoard.rowLengths(2) == [2])
        #expect(PlugBoard.rowLengths(3) == [3])
        #expect(PlugBoard.rowLengths(4) == [2, 2], "not three and one")
        #expect(PlugBoard.rowLengths(5) == [3, 2])
        #expect(PlugBoard.rowLengths(7) == [3, 2, 2])
        let items = (0..<7).map { item("\($0)") }
        #expect(PlugBoard.rows(items).map { $0.map(\.id) } == [["0", "1", "2"], ["3", "4"], ["5", "6"]], "every plug is in one row, in order")
        #expect(PlugBoard.rows([]).isEmpty)
    }

    @Test func plugsReadTheAccessWithTheTrustFirst() {
        let access = DeviceAccess(trusted: true, capabilities: [
            .init(id: DeviceAccess.talk, symbol: "a", title: "Talk", allowed: true),
            .init(id: "g.files", symbol: "b", title: "Files", allowed: false),
            .init(id: "g.look", symbol: "c", title: "Look", allowed: true),
        ])
        let items = PlugItem.items(of: access)
        #expect(items.map(\.id) == [DeviceAccess.talk, "g.files", "g.look"])
        #expect(items.map(\.plugged) == [true, false, true])

        let untrusted = access.plugging(DeviceAccess.talk, false)
        #expect(PlugItem.items(of: untrusted).allSatisfy { !$0.plugged }, "no tool is in while the device is not trusted")
        let back = untrusted.plugging("g.files", true)
        #expect(back.trusted && PlugItem.items(of: back).map(\.plugged) == [true, true, true], "plugging a tool trusts the device too")
    }

    @Test func chipsAreAsWideAsTheLongestNameSoNoNameIsCut() throws {
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: "", imps: [], mcpServers: [], visitors: [])
        let node = try #require(map.nodes.first)
        let long = 18
        let width = DeviceGraph.box(of: node, residents: 3, longestName: long).width
        #expect(width > DeviceGraph.box(of: node, residents: 3).width, "a long name widens the device")
        let frames = DeviceGraph.chipFrames(count: 3, in: width, longestName: long)
        #expect(frames.allSatisfy { $0.width >= DeviceGraph.chipWidth(long) - 0.001 })
    }
}
