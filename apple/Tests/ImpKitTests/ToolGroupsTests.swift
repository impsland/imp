import Foundation
import Testing
@testable import ImpKit

/// The "n of m on" a tool group shows. It counts what the registry's own filter leaves on.
@Suite struct ToolGroupsTests {
    private let server = MCPServerConfig(name: "files", transport: .stdio, command: "x")

    @Test func everyBuiltInGroupIsListedWithAllItsToolsOn() {
        let groups = ToolGroups.own(for: .imp)
        #expect(groups.map(\.id) == ImpToolGroup.allCases.filter { !ToolRegistry.tools(in: $0).isEmpty }.map(ToolRegistry.ownGroupID))
        for group in groups where group.isOn { #expect(group.on == group.tools.count) }
    }

    @Test func aSwitchedOffToolIsNotCounted() throws {
        var imp = ImpProfile.imp
        let body = try #require(ToolGroups.own(for: imp).first { $0.id == ToolRegistry.ownGroupID(.body) })
        imp.setUses(tool: body.tools[0].id, false)
        let after = try #require(ToolGroups.own(for: imp).first { $0.id == body.id })
        #expect(after.on == body.on - 1)
        #expect(after.total == body.total)
    }

    @Test func aSwitchedOffGroupCountsNone() throws {
        var imp = ImpProfile.imp
        imp.setUses(.body, false)
        let body = try #require(ToolGroups.own(for: imp).first { $0.id == ToolRegistry.ownGroupID(.body) })
        #expect(!body.isOn)
        #expect(body.on == 0)
        #expect(body.total > 0)
    }

    @Test func aServerNotUsedByTheImpCountsNone() {
        let groups = ToolGroups.mcp(for: .imp, servers: [server], tools: [server.id: ["read", "write"]])
        #expect(groups.count == 1)
        #expect(groups[0].id == ToolRegistry.mcpGroupID(server: "files"))
        #expect(!groups[0].isOn)
        #expect(groups[0].on == 0)
        #expect(groups[0].total == 2)
    }

    @Test func aServerTheImpUsesCountsItsToolsMinusTheOnesOff() {
        var imp = ImpProfile.imp
        imp.servers = [server.id]
        imp.setUses(tool: ToolRegistry.mcpID(server: "files", tool: "write"), false)
        let group = ToolGroups.mcp(for: imp, servers: [server], tools: [server.id: ["read", "write"]])[0]
        #expect(group.isOn)
        #expect(group.on == 1)
        #expect(group.total == 2)
        #expect(group.tools.map(\.name) == ["read", "write"])
    }

    @Test func aServerThatHasNotStartedHasNoToolsYet() {
        var imp = ImpProfile.imp
        imp.servers = [server.id]
        let group = ToolGroups.mcp(for: imp, servers: [server], tools: [:])[0]
        #expect(group.total == 0)
        #expect(group.on == 0)
    }

    @Test func theSummaryAddsUpEveryGroup() {
        var imp = ImpProfile.imp
        imp.servers = [server.id]
        let groups = ToolGroups.own(for: imp) + ToolGroups.mcp(for: imp, servers: [server], tools: [server.id: ["read"]])
        let (on, total) = ToolGroups.summary(groups)
        #expect(on == groups.map(\.on).reduce(0, +))
        #expect(total == groups.map(\.total).reduce(0, +))
    }
}
