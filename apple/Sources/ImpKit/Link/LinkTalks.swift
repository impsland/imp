import ImpCore
import Foundation

/// Which Imps another Imp may talk to. The core decides.
public enum LinkTalks {
    public static func targets(of asker: UUID, mine: [LinkStaged], stage: [LinkStaged]) -> [LinkStaged] {
        let encoder = JSONEncoder.link
        guard let a = try? encoder.encode(mine), let b = try? encoder.encode(stage),
              let text = try? linkTalkTargets(asker: asker.uuidString, mine: String(decoding: a, as: UTF8.self), stage: String(decoding: b, as: UTF8.self)),
              let found = try? JSONDecoder.link.decode([LinkStaged].self, from: Data(text.utf8)) else { return [] }
        return found
    }
}
