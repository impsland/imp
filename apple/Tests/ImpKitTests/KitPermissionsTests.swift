import Foundation
import Testing
@testable import ImpKit

@Suite struct KitPermissionsTests {
    @Test func listsCommandsTriggersAndComputerControl() throws {
        let json = """
        {"name":"Pack","imps":[{"name":"Bo","tools":{"computer":true}}],
         "mcpServers":{"files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem"]},"web":{"url":"https://mcp.example.org/x"}},
         "triggers":[{"name":"Summarize","do": [{"act": "ask", "value": "Summarize it"}],"on": "battery", "value": 20}]}
        """
        let permissions = try Kit.parse(json).permissions
        let text = permissions.lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("control your Mac"))
        #expect(text.contains("npx -y @modelcontextprotocol/server-filesystem"))
        #expect(text.contains("https://mcp.example.org/x"))
        #expect(text.contains("Summarize"))
        #expect(text.contains("own.body.imp_play_animations"))
        #expect(text.contains("mcp.files.*"))
        #expect(permissions.hasCautions)
    }

    @Test func aPlainAnimationAsksForNothing() throws {
        #expect(try Kit.parse(waveKit).permissions.isEmpty)
    }
}

private let waveKit = #"{"name":"Wave","animations":[{"name":"Wave","beats":[{"duration":0.4,"mood":"happy","tilt":10}]}]}"#

/// The kits in spec/fixtures/kits, and go through the same parser and
/// permission lines the review uses. None may lose an item or carry a secret.
@Suite struct FixtureKitTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../spec/fixtures/kits")

    static var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func allEightAreThere() { #expect(Self.files.count == 8) }

    @Test func everyKitParsesWithoutProblems() throws {
        for file in Self.files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let kit = try Kit.parse(text)
            #expect(kit.problems.isEmpty, "\(file.lastPathComponent): \(kit.problems)")
            #expect(!kit.imps.isEmpty || !kit.triggers.isEmpty || !kit.servers.isEmpty || !kit.animations.isEmpty, "\(file.lastPathComponent) is empty")
            for server in kit.servers {
                #expect(server.environment.values.allSatisfy { $0.isEmpty } && server.headers.values.allSatisfy { $0.isEmpty }, "\(file.lastPathComponent) holds a secret")
            }
            // A review can be built and says what the kit does.
            let permissions = kit.permissions
            for server in kit.servers {
                let all = permissions.lines.map(\.text).joined(separator: "\n")
                #expect(all.contains(server.transport == .stdio ? server.commandLine : server.url), "\(file.lastPathComponent) hides a tool's command")
            }
            for imp in kit.imps where imp.uses(.computer) {
                #expect(permissions.lines.contains { $0.kind == .computer }, "\(file.lastPathComponent) hides computer control")
            }
            #expect(permissions.lines.filter { $0.kind == .trigger }.count == kit.triggers.count + kit.imps.flatMap(\.triggers).count)
            _ = kit.warnings()
        }
    }
}
