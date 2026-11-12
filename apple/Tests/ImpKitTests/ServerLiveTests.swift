// Live Imp server (opt-in): plays this Mac, an iPhone and an Imp against a running Den and Hop.
//   cargo run -p imp-den & cargo run -p imp-hop &  (see server/README.md)
//   IMP_SERVER=http://localhost:8080 swift test --filter ServerLiveTests

import Foundation
import Testing
@testable import ImpKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["IMP_SERVER"] != nil), .serialized)
struct ServerLiveTests {
    private var server: DenServer {
        get throws { try #require(DenServer(ProcessInfo.processInfo.environment["IMP_SERVER"] ?? "")) }
    }

    @Test func anImpMakesAnAccountAndSharesAnAnimation() async throws {
        let den = DenClient(server: try server)
        let challenge = try await den.challenge()
        let solution = try await Altcha.solve(challenge)
        let handle = "live-\(UUID().uuidString.prefix(8).lowercased())"
        let account = try await den.createAccount(handle: handle, altcha: try Altcha.payload(challenge, solution))
        #expect(account.handle == handle)

        let kit = #"{"name":"Wave","animations":[{"name":"Wave","beats":[{"duration":0.4,"mood":"happy","tilt":10},{"duration":0.4,"mood":"happy","tilt":-10}]}]}"#
        let id = try #require(DenItemID(handle: handle, slug: "wave"))
        #expect(try await den.put(id, summary: "A friendly wave.", tags: ["fun"], kit: kit, token: account.token))
        let item = try await den.item(id)
        #expect(item.kind == "animation")
        #expect(try await den.kit(id).contains("\"Wave\""))
        try await den.countInstall(id)

        try await den.delete(id, token: account.token)
        await #expect(throws: DenError.self) { try await den.item(id) }
    }

    /// Publishes, searches, downloads with the checksum check and installs-as-parsed, against a real Den.
    @Test func aPackageIsPublishedFoundAndInstalled() async throws {
        let den = DenClient(server: try server)
        let challenge = try await den.challenge()
        let account = try await den.createAccount(handle: "pkg-\(UUID().uuidString.prefix(8).lowercased())",
                                                  altcha: try Altcha.payload(challenge, try await Altcha.solve(challenge)))
        var ids: [DenItemID] = []
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("../../spec/fixtures/kits")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(files.count == 8)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let id = try #require(DenItemID(handle: account.handle, slug: file.deletingPathExtension().lastPathComponent))
            #expect(try await den.put(id, summary: "Fixture \(id.slug)", tags: ["fixture"], kit: text, token: account.token))
            ids.append(id)
            let download = try await den.download(id)
            let kit = try Kit.parse(download.text)
            #expect(kit.problems.isEmpty)
            #expect(download.item.sha256?.count == 64)
        }
        let found = try await den.items(DenQuery(tag: "fixture", limit: 50))
        #expect(found.items.filter { $0.handle == account.handle }.count == 8)
        for id in ids { try await den.delete(id, token: account.token) }
    }
}

