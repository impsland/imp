import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// `imp_open_file`: an Imp looks at a file it was given. Only a reference an owner made when sharing
/// (`imp-file://`, size and checksum checked) or a file in the Imp's own Workspace can be opened,
/// never an arbitrary path. A picture comes back attached, a text as text, anything else as its
/// name, type, size and path for the shell.
public enum OpenFile {
    /// Longest text handed back, in characters.
    public static let textLimit = 100_000
    /// Longest picture side sent to the model.
    public static let maxPixel = 2048

    /// Opens `file` (a reference exactly as received, or a path in `imp`'s own Workspace).
    /// `workspaces` finds an Imp's Workspace. Throws `ToolArgumentError` with a sentence for the Imp.
    public static func open(_ file: String, imp: UUID,
                            workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) throws -> ToolOutput {
        var text = file.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty else { throw ToolArgumentError("Give the `file`: an imp-file:// link as you received it, or a path in your own folder.") }

        let reference: WorkspaceReference
        if WorkspaceReference.isReference(text) {
            guard let parsed = WorkspaceReference(parsing: text) else { throw ToolArgumentError(WorkspaceReference.Problem.malformed.localizedDescription) }
            reference = parsed
        } else if text.contains("://") {
            throw ToolArgumentError("Only imp-file:// links and files in your own folder can be opened.")
        } else {
            guard let path = WorkspaceReference.relativePath(of: text, in: workspaces(imp)) else {
                throw ToolArgumentError("That path isn't in your own folder, so it isn't opened. Only imp-file:// links and files in your folder can be.")
            }
            reference = WorkspaceReference(owner: imp, path: path)
        }
        let url: URL
        do { url = try reference.resolve(workspaces: workspaces) } catch {
            throw ToolArgumentError(error.localizedDescription)
        }
        // Another Imp's file opens only by the link it shared: that names its size, and its checksum when it is
        // small enough to have one. A link typed without them would open a file nobody shared. (Checked once the
        // link resolves, so a missing file or one on another device is still said as such.)
        if reference.owner != imp,
           reference.size == nil || (reference.sha256 == nil && (reference.size ?? 0) <= WorkspaceReference.checksumLimit) {
            throw ToolArgumentError("That link isn't one another Imp shared (it has no size or checksum), so it isn't opened. Use the link exactly as you received it.")
        }
        return describe(url, hint: reference.type)
    }

    static func describe(_ url: URL, hint: String?) -> ToolOutput {
        let name = url.lastPathComponent
        let path = url.path(percentEncoded: false)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let type = UTType(filenameExtension: url.pathExtension) ?? hint.flatMap { UTType(mimeType: $0) }
        let kind = type?.preferredFilenameExtension?.uppercased() ?? type?.localizedDescription ?? "file"
        let where_ = "Its path on this Mac, for your shell: \(path)"

        if let type, type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let encoded = EncodedImage.encode(image, maxPixel: maxPixel) {
            return ToolOutput("\(name), \(image.width)×\(image.height) \(kind), \(size). The picture is attached. \(where_)", images: [encoded])
        }
        if type?.conforms(to: .pdf) == true, let document = PDFDocument(url: url) {
            let body = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let head = "\(name), PDF, \(document.pageCount) pages, \(size). \(where_)"
            if !body.isEmpty { return ToolOutput(head + "\n\n" + clipped(body)) }
            return ToolOutput(head + " It has no text to read.")
        }
        if let body = textContent(of: url, type: type, bytes: bytes) {
            return ToolOutput("\(name), \(kind), \(size). \(where_)\n\n" + clipped(body))
        }
        return ToolOutput("\(name), \(type?.localizedDescription ?? kind), \(size). It isn't a picture or text, so it can't be shown here. "
                          + "\(where_) Use your shell on that path, for example to copy it into your own folder.")
    }

    private static func clipped(_ body: String) -> String {
        guard body.count > textLimit else { return body }
        return String(body.prefix(textLimit)) + "\n\n[Cut here: the first \(textLimit) characters of \(body.count).]"
    }

    /// The file as text if it is one: a text type, or valid UTF-8 without NUL bytes that is not too big.
    private static func textContent(of url: URL, type: UTType?, bytes: Int) -> String? {
        let known = type.map { $0.conforms(to: .text) || $0.conforms(to: .json) || $0.conforms(to: .sourceCode) || $0.conforms(to: .xml) } ?? false
        guard known || bytes <= 1_000_000 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let cap = textLimit * 4 + 4
        guard var data = try? handle.read(upToCount: cap) else { return nil }
        if !known, data.contains(0) { return nil }
        // A cut in the middle of a character is not an error.
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            if data.count < cap || data.isEmpty { return nil }
            data.removeLast()
        }
        return nil
    }
}
