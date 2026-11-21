import AppKit
import ImpKit

/// The clipboard: what you copied (for shortcuts and pasting into the bubble), and results to copy.
@MainActor
enum Pasteboard {
    static var general: NSPasteboard { .general }

    static func text() -> String? {
        let pb = general
        // A copied file is not "clipboard text" even though it carries its name as a string.
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
           pb.string(forType: .string) == nil { return nil }
        return pb.string(forType: .string)
    }

    /// What you copied, ready for an Imp: words if there are any, else a picture. (Text copied
    /// from many apps carries a rendered picture of itself too. The words are what you meant.)
    /// An image file copied in Finder counts as its picture. Nil when there's nothing usable.
    static func clip() -> Clip? {
        if !copiedImageFile, let s = text(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(s) }
        if let image = image(), let encoded = EncodedImage.encode(image) { return .image(encoded) }
        return nil
    }

    private static var copiedImageFile: Bool {
        let urls = general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first.map { NSImage(contentsOf: $0) != nil } ?? false
    }

    /// What a paste or a drop hands over: files for the message, and why one was left out.
    struct Media {
        var files: [MediaFile] = []
        var problem: MediaFile.Problem?
        var isEmpty: Bool { files.isEmpty && problem == nil }
    }

    /// Files of a drag or the clipboard that an Imp can take: pictures, sounds and videos, then (when
    /// there are no files) the picture itself, from a browser or Photos.
    static func media(from pb: NSPasteboard = general) -> Media {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var result = media(from: urls)
        if urls.isEmpty || (result.files.isEmpty && result.problem == nil),
           let image = image(from: pb), let encoded = EncodedImage.encode(image) {
            result.files = [MediaFile(encoded, name: "picture")]
        }
        return result
    }

    /// Files chosen or dropped by their URLs: pictures, sounds and videos only.
    static func media(from urls: [URL]) -> Media {
        var result = Media()
        for url in urls where mediaKind(of: url) != nil {
            guard MediaFile.canAdd(to: result.files.count) else { result.problem = .tooMany; break }
            do { result.files.append(try MediaFile.load(url)) } catch let problem as MediaFile.Problem { result.problem = problem } catch {
                result.problem = .unreadable
            }
        }
        return result
    }

    /// A paste (⌘V): files you copied, or a picture, but not text.
    static func pastedMedia() -> Media {
        guard copiedMediaFile || copiedImageFile || text()?.isEmpty != false else { return Media() }
        return media()
    }

    private static var copiedMediaFile: Bool {
        let urls = general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.contains { mediaKind(of: $0) != nil } ?? false
    }

    /// Whether a drag carries something an Imp can take (checked cheaply, without reading it).
    static func hasMedia(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.contains { mediaKind(of: $0) != nil }
        }
        return NSImage.canInit(with: pb)
    }

    /// Picture, sound or video by its file (nil for any other kind of file).
    static func mediaKind(of url: URL) -> MediaFile.Kind? {
        let kind = MediaFile.kind(ofMIME: MediaFile.mimeType(forExtension: url.pathExtension))
        if kind == .file {
            let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
            if let type, NSImage.imageTypes.contains(type) { return .image }
            return nil
        }
        return kind
    }

    /// The pasteboard types a file or picture can be dragged in.
    static let pictureTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                              NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("org.webmproject.webp")]

    /// Image data from the clipboard (or a drag), including image files copied in Finder.
    static func image(from pb: NSPasteboard = general) -> CGImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return img
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("org.webmproject.webp"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pb.data(forType: type), let img = EncodedImage.decode(data) { return img }
        }
        if let img = NSImage(pasteboard: pb)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return img }
        return nil
    }

    static func write(text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}
