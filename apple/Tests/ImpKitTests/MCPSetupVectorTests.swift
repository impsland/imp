import Foundation
import Testing
@testable import ImpKit

/// Runs `spec/fixtures/mcp-setup.json` through the app: pasted setup text and command lines read as
/// the core reads them for every client. A server the core names nothing gets the app's own word.
@Suite struct MCPSetupVectorTests {
    static var vectors: [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../spec/fixtures/mcp-setup.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    @Test func setupTextGivesTheVectorsServers() throws {
        let cases = try #require(Self.vectors["setup"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let got = MCPServerConfig.parse(setup: c["text"] as! String)
            let want = c["servers"] as! [[String: Any]]
            #expect(got.count == want.count, "\(c["name"]!)")
            for (server, w) in zip(got, want) {
                #expect(server.name == (w["name"] as? String ?? ""), "\(c["name"]!)")
                #expect(server.transport == ((w["url"] as? String) != nil ? .http : .stdio), "\(c["name"]!)")
                #expect(server.command == (w["command"] as? String ?? ""), "\(c["name"]!)")
                #expect(server.arguments == (w["args"] as? [String] ?? []), "\(c["name"]!)")
                #expect(server.environment == (w["env"] as? [String: String] ?? [:]), "\(c["name"]!)")
                #expect(server.url == (w["url"] as? String ?? ""), "\(c["name"]!)")
                #expect(server.headers == (w["headers"] as? [String: String] ?? [:]), "\(c["name"]!)")
            }
        }
    }

    @Test func commandLinesSplitAndQuoteAsInTheVectors() throws {
        let words = try #require(Self.vectors["words"] as? [[String: Any]])
        for c in words {
            #expect(MCPServerConfig.split(c["line"] as! String) == c["words"] as! [String], "\(c)")
        }
        let quotes = try #require(Self.vectors["quote"] as? [[String: Any]])
        for c in quotes {
            let word = c["word"] as! String
            var server = MCPServerConfig(name: "", transport: .stdio, command: "x", arguments: [word])
            #expect(server.commandLine == "x " + (c["quoted"] as! String), "\(c)")
            server.commandLine = server.commandLine
            #expect(server.arguments == [word], "\(c)")
        }
    }

    @Test func aServerNothingNamesGetsTheAppsWord() {
        #expect(MCPServerConfig.suggestedName(commandLine: []) == String(localized: "New tool"))
        #expect(MCPServerConfig.suggestedName(url: "not an address") == String(localized: "New tool"))
    }
}
