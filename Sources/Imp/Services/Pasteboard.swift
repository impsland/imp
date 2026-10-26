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

    /// A picture you copied (a screenshot, an image, an image file), ready to send.
    static func picture() -> EncodedImage? {
        guard copiedImageFile || text()?.isEmpty != false else { return nil }
        return image().flatMap { EncodedImage.encode($0) }
    }

    private static var copiedImageFile: Bool {
        let urls = general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first.map { NSImage(contentsOf: $0) != nil } ?? false
    }

    /// A picture dragged onto an Imp (an image file from Finder, or an image from a browser or
    /// Photos), ready to send. Nil when the drag carries no picture.
    static func picture(dropped pb: NSPasteboard) -> EncodedImage? {
        image(from: pb).flatMap { EncodedImage.encode($0) }
    }

    /// Whether a drag carries a picture (checked cheaply, without decoding it).
    static func hasPicture(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return NSImage.imageTypes.contains { (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) == $0 }
                || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased())
        }
        return NSImage.canInit(with: pb)
    }

    /// The pasteboard types a picture can be dragged in.
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
