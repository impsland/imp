import Foundation
import Testing
@testable import ImpKit

@MainActor @Suite struct LinkStorageTests {
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("imp-link-\(UUID().uuidString)") }

    @Test func theBookIsPrivateAndReplacedWhole() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("link.json")
        let storage = LinkFileStorage(url: url)
        #expect(try storage.load() == nil)
        try storage.save(Data("first".utf8))
        #expect(try storage.load() == Data("first".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o600 && dirMode == 0o700)
        // Saved again, replaced whole, nothing left beside it.
        try storage.save(Data("second".utf8))
        #expect(try storage.load() == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["link.json"])
    }

    @Test func aBookTheCoreCantReadIsAnErrorNotAFreshStart() throws {
        let storage = LinkMemoryStorage(Data("{ not json".utf8))
        #expect(throws: (any Error).self) { try LinkNode(name: "Mac", kind: .mac, storage: storage) }
    }

    @Test func aSavedBookBringsBackTheSameDevice() throws {
        let storage = LinkMemoryStorage()
        let first = try LinkNode(name: "Mac", kind: .mac, storage: storage)
        let again = try LinkNode(name: "Mac", kind: .mac, storage: storage)
        #expect(again.device.id == first.device.id)
    }

    @Test func memoryStorageKeepsTheLastBook() throws {
        let storage = LinkMemoryStorage()
        #expect(try storage.load() == nil)
        try storage.save(Data([1, 2, 3]))
        #expect(try storage.load() == Data([1, 2, 3]))
    }
}
