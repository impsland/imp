import Foundation
import ImageIO

/// What the home window's canvas shows behind the Imps.
public struct CanvasBackground: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        /// The cosy dungeon wall. The default.
        case theme
        /// One colour.
        case colour
        /// One picture that fills the window.
        case picture
        /// A seamless pattern that repeats.
        case tile

        public var id: String { rawValue }
        public var usesImage: Bool { self == .picture || self == .tile }
    }

    /// A colour as three numbers from 0 to 1.
    public struct Colour: Codable, Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red.clamped01
            self.green = green.clamped01
            self.blue = blue.clamped01
        }

        /// A deep plum, close to the wall.
        public static let plum = Colour(red: 0.12, green: 0.06, blue: 0.11)
    }

    public var kind: Kind = .theme
    public var colour: Colour = .plum
    /// The name of the picture's copy in `BackgroundFiles.folder`, for a picture or a tile.
    public var image: String?

    public init() {}
}

private extension Double {
    var clamped01: Double { isFinite ? min(max(self, 0), 1) : 0 }
}

/// The pictures chosen for the canvas. The app keeps its own copy, so moving or deleting the original
/// breaks nothing.
public enum BackgroundFiles {
    public struct Unusable: Error, Equatable {}

    /// Where the copies live (inside Imp's folder in Application Support, so a reset removes them).
    public static var folder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Imp/Background", isDirectory: true)
    }

    /// Copies a picture into `folder` and returns the copy's file name. Throws `Unusable` for a file
    /// that isn't an image or can't be read. `replacing` (the copy being replaced) is removed after.
    public static func adopt(_ source: URL, into folder: URL = BackgroundFiles.folder, replacing old: String? = nil) throws -> String {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0,
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw Unusable() }
        let ext = source.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        } catch { throw Unusable() }
        if let old { remove(old, in: folder) }
        return name
    }

    /// The copy's place, or nil when the name could point outside the folder.
    public static func url(of name: String, in folder: URL = BackgroundFiles.folder) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != "..", name != "." else { return nil }
        return folder.appendingPathComponent(name)
    }

    public static func remove(_ name: String, in folder: URL = BackgroundFiles.folder) {
        if let url = url(of: name, in: folder) { try? FileManager.default.removeItem(at: url) }
    }
}
