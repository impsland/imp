import Foundation
import Testing
@testable import ImpKit

/// What Settings > Sharing lists, and in which order.
@Suite struct SharingListTests {
    private func troupe() -> (prefs: ImpPreferences, pip: UUID, bob: UUID) {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        return (prefs, pip, bob)
    }

    private func trigger(_ name: String, for imp: UUID? = nil) -> Shortcut {
        var s = Shortcut(name: name, steps: [Step(.ask, value: "Hi")])
        s.performer = imp
        return s
    }

    @Test func triggersListSharedFirstThenByImpThenByNaturalName() {
        var (prefs, pip, bob) = troupe()
        let order = prefs.imps.map(\.id).filter { $0 == pip || $0 == bob }
        prefs.shortcuts = [trigger("B", for: order[1]), trigger("Wave 10", for: order[0]), trigger("z"), trigger("Wave 2", for: order[0]), trigger("a")]
        let listed = prefs.sharableTriggers
        #expect(listed.map(\.shortcut.name) == ["a", "z", "Wave 2", "Wave 10", "B"])
        #expect(listed.map(\.owner) == [nil, nil, order[0], order[0], order[1]])
    }

    @Test func aTriggerOfAnImpThatIsGoneIsLeftOut() {
        var (prefs, _, _) = troupe()
        prefs.shortcuts = [trigger("Ghost", for: UUID()), trigger("Mine")]
        #expect(prefs.sharableTriggers.map(\.shortcut.name) == ["Mine"])
    }

    @Test func animationsListSharedFirstThenEachImpsOwn() throws {
        var (prefs, pip, _) = troupe()
        prefs.animationLibrary = [MadeAnimation(name: "Spin", beats: []), MadeAnimation(name: "Bow", beats: [])]
        let index = try #require(prefs.imps.firstIndex { $0.id == pip })
        prefs.imps[index].animations = [MadeAnimation(name: "Dance", beats: [])]
        let listed = prefs.sharableAnimations
        #expect(listed.map(\.animation.title) == ["Bow", "Spin", "Dance"])
        #expect(listed.map(\.owner) == [nil, nil, pip])
    }

    @Test func serversListByNameWithTheImpsThatUseThem() throws {
        var (prefs, pip, bob) = troupe()
        let b = MCPServerConfig(name: "Notes 10", transport: .http), a = MCPServerConfig(name: "Notes 2", transport: .stdio)
        prefs.mcpServers = [b, a]
        for id in [bob, pip] {
            let index = try #require(prefs.imps.firstIndex { $0.id == id })
            prefs.imps[index].servers = [a.id]
        }
        let listed = prefs.sharableServers
        #expect(listed.map(\.server.name) == ["Notes 2", "Notes 10"])
        #expect(listed[0].users == prefs.imps.map(\.id).filter { $0 == pip || $0 == bob }, "in the order of the Imps")
        #expect(listed[1].users.isEmpty)
    }

    @Test func oneKitOfTriggersCarriesTheAnimationsTheyPlayOnce() {
        var (prefs, _, _) = troupe()
        let wave = MadeAnimation(name: "Wave", beats: [])
        prefs.animationLibrary = [wave]
        let play = Step(.play, value: "Wave")
        prefs.shortcuts = [Shortcut(name: "One", steps: [play]), Shortcut(name: "Two", steps: [play])]
        let kit = prefs.kit(sharing: prefs.shortcuts, named: "Triggers")
        #expect(kit.triggers.count == 2)
        #expect(kit.animations.map(\.name) == ["Wave"])
    }

    @Test func switchingAListedTriggerKeepsItWhereItIs() throws {
        var (prefs, pip, _) = troupe()
        prefs.shortcuts = [trigger("Shared"), trigger("Mine", for: pip)]
        for item in prefs.sharableTriggers { prefs.setEnabled(false, trigger: item) }
        #expect(prefs.shortcuts.count == 2)
        #expect(prefs.shortcuts.allSatisfy { !$0.isEnabled })
        #expect(prefs.shortcuts.map(\.performer).contains(nil) && prefs.shortcuts.map(\.performer).contains(pip))
    }

    @Test func switchingAServerChangesItForEveryImp() throws {
        var (prefs, _, _) = troupe()
        let server = MCPServerConfig(name: "Den", transport: .http)
        prefs.mcpServers = [server]
        prefs.setEnabled(false, server: server.id)
        #expect(prefs.mcpServers.first?.isEnabled == false)
    }
}
