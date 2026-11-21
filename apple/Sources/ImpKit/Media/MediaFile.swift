import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo, a sound, a video or any file that goes along with a message to an Imp.
/// Pictures are scaled (`EncodedImage.encode`); sound the apps record is 16 kHz mono 16-bit WAV.
public struct MediaFile: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case image, audio, video, file
    }

    /// Why a file can't be attached.
    public enum Problem: Error, Equatable, Sendable {
        case tooBig, empty, unreadable, tooMany
    }

    /// The biggest file in bytes (the core's `MAX_MEDIA_BYTES`).
    public static let maxBytes = 25 << 20
    /// The most files in one message (the core's `MAX_ATTACHMENTS`).
    public static let maxCount = 4

    public var id = UUID()
    public var data: Data
    public var mimeType: String
    public var name: String
    /// The file it was read from, if it came from one (to show a video's first frame).
    public var source: URL?

    public init(data: Data, mimeType: String, name: String, source: URL? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.name = name
        self.source = source
    }

    public init(_ image: EncodedImage, name: String = "photo") {
        self.init(data: image.data, mimeType: image.mimeType, name: name)
    }

    public var kind: Kind { Self.kind(ofMIME: mimeType) }
    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    /// The picture, when this is one.
    public var picture: EncodedImage? { kind == .image ? EncodedImage(data: data, mimeType: mimeType) : nil }

    public static func kind(ofMIME mime: String) -> Kind {
        let type = mime.lowercased()
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        return .file
    }

    /// The MIME type for a file name's extension (`application/octet-stream` when unknown).
    public static func mimeType(forExtension ext: String) -> String {
        let lower = ext.lowercased()
        switch lower {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "jpg", "jpeg": return "image/jpeg"
        default: return UTType(filenameExtension: lower)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// The extension a file of this MIME type is saved with.
    public static func fileExtension(forMIME mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        }
    }

    /// Whether a file of `bytes` may be attached.
    public static func check(bytes: Int) -> Problem? {
        bytes <= 0 ? .empty : bytes > maxBytes ? .tooBig : nil
    }

    /// Whether another file fits in a message that has `count` already.
    public static func canAdd(to count: Int) -> Bool { count < maxCount }

    /// Reads a file from disk. Pictures are scaled and re-encoded like a pasted one.
    public static func load(_ url: URL) throws -> MediaFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if let problem = check(bytes: size) { throw problem }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Problem.unreadable }
        let mime = mimeType(forExtension: url.pathExtension)
        let name = url.lastPathComponent
        if kind(ofMIME: mime) == .image, let cg = EncodedImage.decode(data), let encoded = EncodedImage.encode(cg) {
            var file = MediaFile(encoded, name: name)
            file.source = url
            return file
        }
        return MediaFile(data: data, mimeType: mime, name: name, source: url)
    }

    /// The words sent when there are none, as on the web page: one line for what is attached.
    public static func defaultWords(for files: [MediaFile]) -> String {
        let kinds = Set(files.map(\.kind))
        if kinds == [.image] { return "Take a look at this photo." }
        if kinds == [.audio] { return "Listen to this." }
        if kinds == [.video] { return "Watch this." }
        return "Take a look at this."
    }

    /// A name safe in a folder: letters, digits, dash and underscore of the original name's stem,
    /// then the time, then the extension of its type. `taken` says which names already exist.
    public func fileName(at date: Date = Date(), taken: (String) -> Bool = { _ in false }) -> String {
        let stem = (name as NSString).deletingPathExtension
        var clean = String(stem.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_" ? Character(scalar) : "-"
        })
        while clean.contains("--") { clean = clean.replacingOccurrences(of: "--", with: "-") }
        clean = String(clean.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).prefix(40))
        if clean.isEmpty {
            clean = switch kind {
            case .image: "picture"
            case .audio: "sound"
            case .video: "video"
            case .file: "file"
            }
        }
        let ext = Self.fileExtension(forMIME: mimeType)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        var candidate = "\(clean)-\(stamp).\(ext)"
        var n = 2
        while taken(candidate) {
            candidate = "\(clean)-\(stamp)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }
}

/// The 44 bytes that start a WAV file with PCM in it.
public enum WavHeader {
    public struct Info: Equatable, Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int
        public var dataBytes: Int
    }

    /// The header for `dataBytes` of PCM.
    public static func make(sampleRate: Int, channels: Int, bitsPerSample: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bitsPerSample / 8); u16(channels * bitsPerSample / 8); u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// What a PCM WAV file says about itself (nil when it isn't one). Walks the chunks, since
    /// recorders add some of their own before `data`.
    public static func parse(_ data: Data) -> Info? {
        let b = [UInt8](data.prefix(4096))
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var i = 12
        var format: (Int, Int, Int)?
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self), size = u32(i + 4)
            if id == "fmt ", i + 24 <= b.count, u16(i + 8) == 1 { format = (u32(i + 12), u16(i + 10), u16(i + 22)) }
            if id == "data" {
                guard let f = format else { return nil }
                return Info(sampleRate: f.0, channels: f.1, bitsPerSample: f.2, dataBytes: min(size, max(0, data.count - (i + 8))))
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }
}
