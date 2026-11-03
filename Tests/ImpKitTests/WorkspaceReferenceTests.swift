import Foundation
import Testing
@testable import ImpKit

/// Workspace file references (`imp-file://…`): the shared vectors in `Tests/Fixtures/workspace-refs.json`,
/// then the checks that need real files.
@Suite struct WorkspaceReferenceTests {
    // MARK: Shared vectors

    private struct Vectors: Decodable {
        struct Normalize: Decodable { let input: String; let result: String? }
        struct Path: Decodable { let name: String; let input: String; let result: String? }
        struct Ref: Decodable {
            let name: String, ref: String
            let valid: Bool?
            let owner: String?, path: String?, sha256: String?, type: String?
            let size: Int?
        }
        struct Checksum: Decodable { let text: String; let sha256: String }
        let owner: String
        let root: String
        let normalize: [Normalize]
        let paths: [Path]
        let refs: [Ref]
        let checksums: [Checksum]
    }

    private static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/workspace-refs.json")
        guard let data = try? Data(contentsOf: url), let found = try? JSONDecoder().decode(Vectors.self, from: data) else {
            fatalError("Tests/Fixtures/workspace-refs.json is missing or unreadable")
        }
        return found
    }()

    @Test func normalizeVectors() {
        for v in Self.vectors.normalize {
            #expect(WorkspaceReference.normalize(v.input) == v.result, "\(v.input.debugDescription)")
        }
    }

    @Test func pathVectors() {
        let root = URL(fileURLWithPath: Self.vectors.root, isDirectory: true)
        for v in Self.vectors.paths {
            #expect(WorkspaceReference.relativePath(of: v.input, in: root) == v.result, "\(v.name)")
        }
    }

    @Test func referenceVectors() {
        for v in Self.vectors.refs {
            let parsed = WorkspaceReference(parsing: v.ref)
            if v.valid == false {
                #expect(parsed == nil, "\(v.name)")
                continue
            }
            #expect(parsed?.owner.uuidString.lowercased() == v.owner, "\(v.name)")
            #expect(parsed?.path == v.path, "\(v.name)")
            #expect(parsed?.size == v.size, "\(v.name)")
            #expect(parsed?.sha256 == v.sha256, "\(v.name)")
            #expect(parsed?.type == v.type, "\(v.name)")
        }
    }

    @Test func checksumVectors() {
        for v in Self.vectors.checksums {
            #expect(WorkspaceReference.checksum(of: Data(v.text.utf8)) == v.sha256, "\(v.text)")
        }
    }

    @Test func writtenReferencesReadBack() throws {
        let owner = try #require(UUID(uuidString: Self.vectors.owner))
        let ref = WorkspaceReference(owner: owner, path: "my pics (1)/cat & dog.png", size: 12, sha256: String(repeating: "ab", count: 32),
                                     type: "image/svg+xml", fragment: "autoplay")
        #expect(!ref.string.contains(" "))
        #expect(!ref.string.contains("("))
        #expect(WorkspaceReference(parsing: ref.string) == ref)
    }

    // MARK: Real files

    /// Two Imps' Workspaces in a temporary folder.
    private struct Rig {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("imp-wsref-\(UUID().uuidString)", isDirectory: true)
        let pip = UUID(), bo = UUID()
        func root(_ imp: UUID) -> URL { top.appendingPathComponent(imp.uuidString, isDirectory: true) }
        var workspaces: (UUID) -> URL { { root($0) } }

        init() throws {
            for imp in [pip, bo] { try FileManager.default.createDirectory(at: root(imp), withIntermediateDirectories: true) }
        }
        @discardableResult func write(_ text: String, _ path: String, in imp: UUID) throws -> URL {
            let url = root(imp).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        func clean() { try? FileManager.default.removeItem(at: top) }
    }

    @Test func aFileSentToAnotherImpOpensThere() throws {
        let rig = try Rig(); defer { rig.clean() }
        let file = try rig.write("hello", "pics/cat.png", in: rig.pip)
        let said = "Here you go: ![my cat](pics/cat.png) and [the same](<./pics/cat.png#x>)"
        let sent = WorkspaceReference.canonicalize(said, owner: rig.pip, root: rig.root(rig.pip))
        #expect(!sent.contains("](pics/cat.png)"))
        // Whoever reads it (the other Imp, on this device) resolves it to the very same file.
        let refs = LinkFiles.references(in: [sent])
        #expect(refs.count == 2)
        for text in refs {
            let named = try #require(WorkspaceReference(parsing: text))
            #expect(named.owner == rig.pip)
            #expect(named.size == 5)
            #expect(named.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            #expect(named.type == "image/png")
            let found = try named.resolve(workspaces: rig.workspaces)
            #expect(LinkFiles.real(found) == LinkFiles.real(file))
        }
        // Bo's Workspace has no such file, but the reference names Pip's.
        let blocks = Markdown.checkingFiles(Markdown.blocks(sent), base: rig.root(rig.bo), workspaces: rig.workspaces)
        guard case .image(let url, _, _)? = blocks.first(where: { if case .image = $0 { true } else { false } }) else {
            Issue.record("the picture is gone"); return
        }
        #expect(url.isFileURL && url.lastPathComponent == "cat.png")
    }

    @Test func fragmentsAreKept() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write("voice", "voice.mp3", in: rig.pip)
        let sent = WorkspaceReference.canonicalize("![hi](voice.mp3#autoplay)", owner: rig.pip, root: rig.root(rig.pip))
        guard case .media(let url, _, let kind, let autoplay)? = Markdown.blocks(sent).first else {
            Issue.record("not media: \(sent)"); return
        }
        #expect(kind == .audio && autoplay)
        #expect(WorkspaceReference(parsing: url.absoluteString)?.path == "voice.mp3")
    }

    @Test func onlyFilesInTheWorkspaceAreNamed() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write("secret", "../outside.txt", in: rig.pip)
        let outside = rig.root(rig.pip).deletingLastPathComponent().appendingPathComponent("elsewhere.txt")
        try Data("x".utf8).write(to: outside)
        try rig.write("mine", "ok.txt", in: rig.bo)
        let said = "[a](../outside.txt) [b](\(outside.path)) [c](missing.txt) [d](https://example.com/x.png) [e](../\(rig.bo.uuidString)/ok.txt)"
        #expect(WorkspaceReference.canonicalize(said, owner: rig.pip, root: rig.root(rig.pip)) == said)
    }

    @Test func linksOutOfTheWorkspaceAreRefused() throws {
        let rig = try Rig(); defer { rig.clean() }
        let secret = rig.top.appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: rig.root(rig.pip).appendingPathComponent("link.txt"), withDestinationURL: secret)
        #expect(WorkspaceReference.make(owner: rig.pip, ref: "link.txt", in: rig.root(rig.pip)) == nil)
        let named = WorkspaceReference(owner: rig.pip, path: "link.txt")
        #expect(throws: WorkspaceReference.Problem.outsideWorkspace) { try named.resolve(workspaces: rig.workspaces) }
    }

    @Test func checksAndSizesAreVerified() throws {
        let rig = try Rig(); defer { rig.clean() }
        let file = try rig.write("hello", "a.txt", in: rig.pip)
        let good = try #require(WorkspaceReference.make(owner: rig.pip, ref: "a.txt", in: rig.root(rig.pip)))
        _ = try good.resolve(workspaces: rig.workspaces)
        // Same length, other content: the checksum catches it.
        try Data("hellp".utf8).write(to: file)
        #expect(throws: WorkspaceReference.Problem.changed) { try good.resolve(workspaces: rig.workspaces) }
        // Other length: the size does.
        try Data("hello!".utf8).write(to: file)
        var sizeOnly = good; sizeOnly.sha256 = nil
        #expect(throws: WorkspaceReference.Problem.changed) { try sizeOnly.resolve(workspaces: rig.workspaces) }
        // Without a size or checksum there is nothing to compare.
        _ = try WorkspaceReference(owner: rig.pip, path: "a.txt").resolve(workspaces: rig.workspaces)
    }

    @Test func missingThingsHaveReadableReasons() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write("x", "folder/inner.txt", in: rig.pip)
        #expect(throws: WorkspaceReference.Problem.missing) { try WorkspaceReference(owner: rig.pip, path: "gone.txt").resolve(workspaces: rig.workspaces) }
        #expect(throws: WorkspaceReference.Problem.notAFile) { try WorkspaceReference(owner: rig.pip, path: "folder").resolve(workspaces: rig.workspaces) }
        #expect(throws: WorkspaceReference.Problem.otherDevice) { try WorkspaceReference(owner: UUID(), path: "a.txt").resolve(workspaces: rig.workspaces) }
        for problem: WorkspaceReference.Problem in [.malformed, .outsideWorkspace, .otherDevice, .missing, .notAFile, .changed] {
            #expect(!(problem.errorDescription ?? "").isEmpty)
        }
    }

    @Test func brokenFilesShowAMessageNotABrokenLink() throws {
        let rig = try Rig(); defer { rig.clean() }
        let owner = rig.pip.uuidString
        let text = """
        ![cat](imp-file://\(owner)/gone.png?size=3)

        ![](voice.mp3)

        See [the report](report.pdf) and [bad](imp-file://\(owner)/../x) and [web](https://example.com).
        """
        let blocks = Markdown.checkingFiles(Markdown.blocks(text), base: rig.root(rig.bo), workspaces: rig.workspaces)
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let s): lines.append(String(s.characters))
            case .image, .media: Issue.record("a missing file is still drawn")
            default: break
            }
        }
        #expect(lines.count == 3)
        #expect(lines[0].contains("cat") && lines[0].contains("isn't there any more"))
        #expect(lines[1].contains("voice.mp3"))
        #expect(lines[2].contains("the report") && lines[2].contains("isn't there any more"))
        #expect(lines[2].contains("broken"))
        // The web link is still a link, the files are not.
        if case .paragraph(let s) = blocks.last {
            let links = s.runs.compactMap(\.link)
            #expect(links.map(\.absoluteString) == ["https://example.com"])
        }
    }

    @Test func oldRelativeReferencesStillOpenInTheirOwnWorkspace() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write("x", "pic.png", in: rig.pip)
        let blocks = Markdown.checkingFiles(Markdown.blocks("![](pic.png)"), base: rig.root(rig.pip), workspaces: rig.workspaces)
        guard case .image(let url, _, _)? = blocks.first else { Issue.record("no picture"); return }
        #expect(url.lastPathComponent == "pic.png")
        // The same words in another Imp's chat find nothing, and say so.
        let other = Markdown.checkingFiles(Markdown.blocks("![](pic.png)"), base: rig.root(rig.bo), workspaces: rig.workspaces)
        if case .paragraph? = other.first {} else { Issue.record("expected a message") }
    }

    @Test func aFileFromAnotherImpIsServedOnlyToTrustedDevices() throws {
        let rig = try Rig(); defer { rig.clean() }
        try rig.write("hello", "cat.png", in: rig.pip)
        let made = try #require(WorkspaceReference.make(owner: rig.pip, ref: "cat.png", in: rig.root(rig.pip)))
        let chat = ["Pip sent ![cat](\(made.string))"]
        // Bo's chat shows Pip's file: the phone asks Bo's home for it.
        #expect(LinkFiles.mayServe(made.string, base: rig.root(rig.bo), in: chat, trusted: true, workspaces: rig.workspaces))
        #expect(!LinkFiles.mayServe(made.string, base: rig.root(rig.bo), in: chat, trusted: false, workspaces: rig.workspaces))
        #expect(LinkFiles.mayServe(made.string, base: rig.root(rig.pip), in: chat, trusted: false, workspaces: rig.workspaces))
        // Never a file the chat doesn't show.
        var other = made; other.path = "other.png"
        #expect(!LinkFiles.mayServe(other.string, base: rig.root(rig.bo), in: chat, trusted: true, workspaces: rig.workspaces))
    }

    @Test func referenceRangesMatchReferences() {
        let text = "![a](x.png \"t\") [b](<my file.png>) <img src=\"y.png\"> [c](f(1).png)"
        let ranges = LinkFiles.referenceRanges(in: text).map { String(text[$0]) }
        #expect(ranges == LinkFiles.references(in: [text]))
        #expect(ranges == ["x.png", "my file.png", "f(1).png", "y.png"])
    }
}
