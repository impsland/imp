import Foundation
import Testing
@testable import ImpKit

@Suite struct CanvasBackgroundTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imp-bg-\(UUID().uuidString)", isDirectory: true)
    }

    /// A 1 x 1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    @Test func defaultsNeedNoSavedValue() throws {
        let saved = try JSONEncoder().encode(ImpPreferences())
        var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "canvasBackground")
        let loaded = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(loaded.background.kind == .theme)
    }

    @Test func choicesSurviveSaving() throws {
        var prefs = ImpPreferences()
        prefs.background.kind = .tile
        prefs.background.image = "a.png"
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.background.kind == .tile && back.background.image == "a.png")
    }

    @Test func adoptCopiesAPictureAndRemovesTheOldCopy() throws {
        let dir = folder(), source = dir.appendingPathComponent("original.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.png.write(to: source)
        let first = try BackgroundFiles.adopt(source, into: dir.appendingPathComponent("copies"))
        try FileManager.default.removeItem(at: source)                     // the original goes away
        let copy = try #require(BackgroundFiles.url(of: first, in: dir.appendingPathComponent("copies")))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        try Self.png.write(to: source)
        _ = try BackgroundFiles.adopt(source, into: dir.appendingPathComponent("copies"), replacing: first)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aFileThatIsNotAPictureIsRefused() throws {
        let dir = folder(), source = dir.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: source)
        #expect(throws: BackgroundFiles.Unusable.self) { try BackgroundFiles.adopt(source, into: dir.appendingPathComponent("copies")) }
    }

    @Test func aNameCannotLeaveTheFolder() {
        #expect(BackgroundFiles.url(of: "../keys.json") == nil)
        #expect(BackgroundFiles.url(of: "") == nil)
        #expect(BackgroundFiles.url(of: "a.png") != nil)
    }
}
