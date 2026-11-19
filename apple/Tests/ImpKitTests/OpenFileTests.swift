import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// `imp_open_file`: what an Imp can open, and what it gets back.
@Suite struct OpenFileTests {
    private struct Rig {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("imp-open-\(UUID().uuidString)", isDirectory: true)
        let me = UUID(), pip = UUID()
        func root(_ imp: UUID) -> URL { top.appendingPathComponent(imp.uuidString, isDirectory: true) }
        var workspaces: (UUID) -> URL { { root($0) } }
        init() throws {
            for imp in [me, pip] { try FileManager.default.createDirectory(at: root(imp), withIntermediateDirectories: true) }
        }
        @discardableResult func write(_ data: Data, _ path: String, in imp: UUID) throws -> URL {
            let url = root(imp).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func reference(_ path: String, of imp: UUID) throws -> String {
            try #require(WorkspaceReference.make(owner: imp, ref: path, in: root(imp))).string
        }
        func open(_ file: String) throws -> ToolOutput { try OpenFile.open(file, imp: me, workspaces: workspaces) }
        func clean() { try? FileManager.default.removeItem(at: top) }
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(context)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        return try #require(EncodedImage.encode(image)).data
    }

    @Test func aSharedPictureComesBackAttached() throws {
        let rig = try Rig(); defer { rig.clean() }
        let file = try rig.write(try Self.png(width: 40, height: 20), "shots/screenshot.png", in: rig.pip)
        let out = try rig.open(try rig.reference("shots/screenshot.png", of: rig.pip))
        #expect(out.images.count == 1)
        #expect(out.images[0].mimeType == "image/png")
        #expect(out.text.contains("screenshot.png, 40×20 PNG"))
        #expect(out.text.contains("The picture is attached."))
        #expect(out.text.contains(file.resolvingSymlinksInPath().path(percentEncoded: false)) || out.text.contains(file.path(percentEncoded: false)))
    }

    /// A link to another Imp's file typed without the size and checksum a shared one has: not opened.
    @Test func aBareLinkToAnotherImpsFileIsRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write(Data("secret".utf8), "notes.txt", in: rig.pip)
        #expect(throws: ToolArgumentError.self) { try rig.open("imp-file://\(rig.pip.uuidString)/notes.txt") }
        #expect(try rig.open(try rig.reference("notes.txt", of: rig.pip)).text.contains("secret"))
    }

    @Test func aSharedTextIsRead() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write(Data("hello from Pip".utf8), "notes.txt", in: rig.pip)
        let out = try rig.open(try rig.reference("notes.txt", of: rig.pip))
        #expect(out.images.isEmpty)
        #expect(out.text.contains("hello from Pip"))
        #expect(out.text.contains("notes.txt"))
    }

    @Test func aLongTextIsCutWithANote() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write(Data(String(repeating: "abcdefghij", count: OpenFile.textLimit / 5).utf8), "big.txt", in: rig.me)
        let out = try rig.open("big.txt")
        #expect(out.text.contains("[Cut here"))
        #expect(out.text.count < OpenFile.textLimit + 1000)
    }

    @Test func otherFilesGiveThePathForTheShell() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write(Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 1, 2, 3]), "bundle.zip", in: rig.pip)
        let out = try rig.open(try rig.reference("bundle.zip", of: rig.pip))
        #expect(out.images.isEmpty)
        #expect(out.text.contains("bundle.zip"))
        #expect(out.text.contains("shell"))
        #expect(out.text.contains(rig.root(rig.pip).lastPathComponent))
    }

    @Test func aFileInTheImpsOwnFolderOpensByPath() throws {
        let rig = try Rig(); defer { rig.clean() }
        let file = try rig.write(Data("mine".utf8), "a/b.md", in: rig.me)
        #expect(try rig.open("a/b.md").text.contains("mine"))
        #expect(try rig.open(file.path(percentEncoded: false)).text.contains("mine"))
    }

    @Test func aChangedFileIsRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write(Data("one".utf8), "n.txt", in: rig.pip)
        let ref = try rig.reference("n.txt", of: rig.pip)
        try rig.write(Data("two".utf8), "n.txt", in: rig.pip)         // same size, other content
        #expect(throws: ToolArgumentError(WorkspaceReference.Problem.changed.localizedDescription)) { try rig.open(ref) }
    }

    @Test func brokenAndMissingReferencesAreRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        #expect(throws: ToolArgumentError.self) { try rig.open("imp-file://not-a-uuid/x.txt") }
        #expect(throws: ToolArgumentError.self) { try rig.open("imp-file://\(rig.pip.uuidString)/../etc/passwd") }
        #expect(throws: ToolArgumentError(WorkspaceReference.Problem.missing.localizedDescription)) {
            try rig.open("imp-file://\(rig.pip.uuidString)/gone.txt")
        }
        #expect(throws: ToolArgumentError(WorkspaceReference.Problem.otherDevice.localizedDescription)) {
            try rig.open("imp-file://\(UUID().uuidString)/gone.txt")
        }
        #expect(throws: ToolArgumentError.self) { try rig.open("") }
    }

    @Test func pathsOutsideTheFolderAreRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        let secret = try rig.write(Data("secret".utf8), "secret.txt", in: rig.pip)      // another Imp's folder
        #expect(throws: ToolArgumentError.self) { try rig.open(secret.path(percentEncoded: false)) }
        #expect(throws: ToolArgumentError.self) { try rig.open("/etc/hosts") }
        #expect(throws: ToolArgumentError.self) { try rig.open("../\(rig.pip.uuidString)/secret.txt") }
        #expect(throws: ToolArgumentError.self) { try rig.open("https://example.com/a.png") }
        #expect(throws: ToolArgumentError.self) { try rig.open("file:///etc/hosts") }
    }

    @Test func aLinkOutOfTheFolderIsRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        let target = try rig.write(Data("secret".utf8), "private/secret.txt", in: rig.me)
        let link = rig.root(rig.pip).appendingPathComponent("peek.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ToolArgumentError.self) { try rig.open("imp-file://\(rig.pip.uuidString)/peek.txt") }
    }

    @Test func theToolIsOfferedWithMessaging() {
        let with = OwnTools.specs([.personality], animations: [], imps: ["Mo"], browser: false).map(\.name)
        #expect(with.contains(OwnTools.openFile))
        #expect(!OwnTools.specs([.animations], animations: ["wave"], imps: ["Mo"], browser: false).map(\.name).contains(OwnTools.openFile))
        #expect(OwnTools.messageSpec(imps: ["Mo"]).description.contains(OwnTools.openFile))
    }
}
