import Foundation
import Testing
@testable import ImpKit

/// A file an Imp shows in a talk with another Imp (`![](todo-done.png)`, in its own folder) reaches the phone:
/// sent as a link of the Imp that wrote it, it may be fetched through any Imp the phone holds.
@Suite struct TalkFilesTests {
    @Test func aTalksFileIsSharedAsItsWritersLinkAndServedThroughAnotherImp() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("imp-talk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: top) }
        let clove = UUID(), imp = UUID()
        let root = { (id: UUID) in top.appendingPathComponent(id.uuidString, isDirectory: true) }
        for id in [clove, imp] { try FileManager.default.createDirectory(at: root(id), withIntermediateDirectories: true) }
        try Data("png".utf8).write(to: root(clove).appendingPathComponent("todo-done.png"))

        let reply = WorkspaceReference.canonicalize("Screenshot: ![Current screen](todo-done.png)", owner: clove, root: root(clove))
        let ref = try #require(LinkFiles.references(in: [reply]).first)
        let named = try #require(WorkspaceReference(parsing: ref))
        #expect(named.owner == clove && named.size == 3 && named.sha256 != nil)

        // Asked through the other Imp, whose folder it isn't in: served to a device marked Mine, not to another.
        #expect(LinkFiles.mayServe(ref, base: root(imp), in: [reply], trusted: true, workspaces: root))
        #expect(!LinkFiles.mayServe(ref, base: root(imp), in: [reply], trusted: false, workspaces: root))
        // Not in the talk: never.
        #expect(!LinkFiles.mayServe(ref, base: root(imp), in: ["nothing here"], trusted: true, workspaces: root))
    }
}
