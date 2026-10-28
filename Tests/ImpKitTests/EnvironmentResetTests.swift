import Foundation
import Testing
@testable import ImpKit

/// The user's shell environment for child processes, a stdio server's last words, and the reset.
struct LoginEnvironmentTests {
    @Test func parsesBetweenMarkers() {
        let m = LoginEnvironment.marker
        var data = Data("Welcome back!\n\(m)".utf8)
        for pair in ["PATH=/a:/b", "NVM_DIR=/x/.nvm", "EQ=a=b", "SHLVL=2", "_=/usr/bin/env", "=junk"] {
            data.append(Data(pair.utf8)); data.append(0)
        }
        data.append(Data("\(m)trailing chatter".utf8))
        let env = LoginEnvironment.parse(data, marker: m)
        #expect(env == ["PATH": "/a:/b", "NVM_DIR": "/x/.nvm", "EQ": "a=b"])
    }

    @Test func rejectsIncompleteOutput() {
        let m = LoginEnvironment.marker
        #expect(LoginEnvironment.parse(Data("\(m)PATH=/a\0".utf8), marker: m) == nil)       // never finished
        #expect(LoginEnvironment.parse(Data("\(m)HOME=/h\0\(m)".utf8), marker: m) == nil)  // no PATH: not trusted
    }

    @Test func resolvesAPath() async {
        let env = await LoginEnvironment.resolved()
        #expect(env["PATH"]?.isEmpty == false)
    }
}

struct StdioLastWordsTests {
    @Test func summarisesStderr() {
        #expect(StdioTransport.summary(stderr: "", status: 0) == nil)
        #expect(StdioTransport.summary(stderr: "", status: 127) == "Command not found.")
        #expect(StdioTransport.summary(stderr: "\n", status: 3) == "It exited with status 3.")
        #expect(StdioTransport.summary(stderr: "a\nb\n\nc\nd\n", status: 1) == "b c d")
        let long = String(repeating: "x", count: 1000)
        let s = StdioTransport.summary(stderr: long, status: 1)
        #expect(s?.count == 400 && s?.hasPrefix("…") == true)
    }

    @Test func missingCommandSaysWhy() async throws {
        let config = MCPServerConfig(name: "ghost", transport: .stdio, command: "imp-no-such-command-\(UUID().uuidString.prefix(8))")
        let client = try MCPClient(config: config)
        do {
            try await client.connect()
            Issue.record("connected to a command that doesn't exist")
        } catch let error as MCPError {
            let text = error.localizedDescription
            #expect(text.hasPrefix("The MCP server closed the connection: "))
            #expect(text.contains("not found"))
        }
        await client.close()
    }
}

struct FactoryResetTests {
    @Test func erasesDefaultsAndFolders() throws {
        let suite = "imp-reset-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        PreferencesStore(defaults: defaults).save(ImpPreferences())
        defaults.set("frame", forKey: "NSWindow Frame ImpHome")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-reset-\(UUID().uuidString)")
        let support = root.appendingPathComponent("Imp/Workspace/x", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Imp/keys.json"))
        let missing = root.appendingPathComponent("never-made")

        let left = FactoryReset(defaults: defaults, domain: suite,
                                folders: [root.appendingPathComponent("Imp"), missing], keychainService: nil).erase()

        #expect(left.isEmpty)
        #expect(defaults.data(forKey: PreferencesStore.key) == nil)
        #expect(defaults.string(forKey: "NSWindow Frame ImpHome") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Imp").path))
        #expect(PreferencesStore(defaults: defaults).load() == ImpPreferences())
        try? FileManager.default.removeItem(at: root)
    }
}
