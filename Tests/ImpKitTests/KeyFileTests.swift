import Foundation
import Testing
@testable import ImpKit

@Suite struct KeyFileTests {
    let file = KeyFile(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("imp-keys-\(UUID().uuidString)/keys.json"))

    @Test func keysAreSavedPrivatelyAndRemoved() throws {
        #expect(file.read("a") == nil)
        #expect(file.write("sk-1", account: "a") && file.write("sk-2", account: "b"))
        #expect(file.read("a") == "sk-1" && file.all() == ["a": "sk-1", "b": "sk-2"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "only the user's account can read it")
        file.write("", account: "a")
        #expect(file.all() == ["b": "sk-2"])
        file.write("", account: "b")
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "no keys, no file")
    }

    @Test func theKeychainIsOptIn() throws {
        var p = ImpPreferences()
        #expect(!p.keysInKeychain)
        p.keysInKeychain = true
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.keysInKeychain)
    }
}
