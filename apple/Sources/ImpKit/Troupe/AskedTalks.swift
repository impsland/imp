import Foundation
import Observation

/// What the Imps of this device asked Imps on other devices, and the answers they got.
///
/// An exchange is filed by the Imp that answered (`TalkLog`), on its own device. When that device is
/// another one (an iPhone Imp asks a Mac Imp), the asker's device would never see it again: its Talks
/// would only show what others asked. So the asker keeps its own copy here. The line's id is the id of
/// the question on the link, and the answering device files its turn under that same id, so when both
/// copies meet (a visitor's home sends its lines) `TalkLog` counts the exchange once.
///
/// Nothing new travels: the asker saw the question and the answer anyway. Kept in one small file, the
/// newest lines only, and an Imp's lines go with it when it says goodbye.
@MainActor @Observable
public final class AskedTalks {
    /// Lines kept in all, oldest dropped first, so the file stays small.
    public static let maxKept = 600

    public private(set) var lines: [TalkLine]
    @ObservationIgnored private let file: URL?

    /// `file` nil keeps nothing on disk (tests, previews).
    public init(file: URL?) {
        self.file = file
        lines = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder.talks.decode([TalkLine].self, from: $0) } ?? []
    }

    /// One exchange an Imp here had with an Imp elsewhere. A line already kept (the same id) is replaced.
    public func record(_ line: TalkLine) {
        var next = lines.filter { $0.id != line.id }
        next.append(TalkLog.forLink([line], limit: 1)[0])
        lines = Array(next.suffix(Self.maxKept))
        save()
    }

    /// Lets go of everything an Imp here asked (it said goodbye).
    public func forget(imp: UUID) {
        guard lines.contains(where: { $0.asker.id == imp }) else { return }
        lines.removeAll { $0.asker.id == imp }
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder.talks.encode(lines) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONEncoder {
    static var talks: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

private extension JSONDecoder {
    static var talks: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
