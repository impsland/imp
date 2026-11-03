import CryptoKit
import Foundation
import Testing
@testable import ImpKit

private func sha(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let waveKit = #"{"imp":3,"name":"Wave","animations":[{"name":"Wave","beats":[{"duration":0.4,"mood":"happy","tilt":10}]}]}"#

/// Installing from the Den: the bytes downloaded must hash to the checksum the Den lists.
extension DenClientTests {
    private func serve(kit: String, listed: String?) {
        let item: String = listed.map { #"{"handle":"pip-3x9k","slug":"wave","kind":"animation","sha256":"\#($0)"}"# }
            ?? #"{"handle":"pip-3x9k","slug":"wave","kind":"animation"}"#
        DenStub.handler = { request in
            request.url?.path.hasSuffix("kit.json") == true ? Self.json(kit) : Self.json(item)
        }
    }

    @Test func aMatchingChecksumInstalls() async throws {
        serve(kit: waveKit, listed: sha(waveKit))
        let download = try await client().download(DenItemID("pip-3x9k/wave")!)
        #expect(download.text == waveKit)
        #expect(try Kit.parse(download.text).animations.count == 1)
    }

    @Test func theChecksumMayBeInCapitals() async throws {
        serve(kit: waveKit, listed: sha(waveKit).uppercased())
        _ = try await client().download(DenItemID("pip-3x9k/wave")!)
    }

    @Test func aChangedDownloadIsRejected() async throws {
        serve(kit: waveKit.replacingOccurrences(of: "Wave", with: "Wavy"), listed: sha(waveKit))
        let error = try await #require(throws: DenError.self) { _ = try await client().download(DenItemID("pip-3x9k/wave")!) }
        #expect(error == DenError.checksum)
    }

    @Test func noChecksumOrAMalformedOneIsRejected() async throws {
        for listed in [nil, "", "abc", String(repeating: "z", count: 64), String(repeating: "a", count: 63)] {
            serve(kit: waveKit, listed: listed)
            let error = try await #require(throws: DenError.self) { _ = try await client().download(DenItemID("pip-3x9k/wave")!) }
            #expect(error == DenError.noChecksum)
        }
    }

    @Test func anUnknownKindIsTreatedAsAKit() throws {
        let item = try JSONDecoder().decode(DenItem.self, from: Data(#"{"handle":"pip-3x9k","slug":"x","kind":"<script>"}"#.utf8))
        #expect(item.kind == "kit")
    }
}

/// The review lists what a kit can do, read from the kit itself.
@Suite struct KitPermissionsTests {
    @Test func listsCommandsTriggersAndComputerControl() throws {
        let json = """
        {"imp":2,"name":"Pack","imps":[{"name":"Bo","tools":{"computer":true}}],
         "mcpServers":{"files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem"]},"web":{"url":"https://mcp.example.org/x"}},
         "triggers":[{"name":"Summarize","prompt":"Summarize it","when":{"kind":"battery","number":20}}]}
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

/// The eight kits the old registry held now live as fixtures, and go through the same parser and
/// permission lines the review uses. None may lose an item or carry a secret.
@Suite struct FixtureKitTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/kits")

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
