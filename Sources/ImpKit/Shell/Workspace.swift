import Foundation

/// An Imp's own folder: where its commands start and where pictures you hand it are saved, so its
/// commands can work on them (`~/Library/Application Support/Imp/Workspace/<id>`).
public enum Workspace {
    public static func directory(for imp: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Imp/Workspace/\(imp.uuidString)", isDirectory: true)
    }

    /// Saves a picture into `directory/attachments` with a fresh name. Its file URL.
    public static func save(_ picture: EncodedImage, in directory: URL, at date: Date = Date()) throws -> URL {
        let folder = directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        let ext = picture.mimeType == "image/jpeg" ? "jpg" : "png"
        var url = folder.appendingPathComponent("picture-\(stamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("picture-\(stamp)-\(n).\(ext)")
            n += 1
        }
        try picture.data.write(to: url)
        return url
    }
}
