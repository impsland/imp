import Foundation
import ImpKit

extension AppModel {
    /// Everything the Imps said to each other, from every Imp's chats: the ones that are out
    /// through their live history, the ones at home from their files. The files are read off the
    /// main actor (chats can be many). Offscreen renders and tests never read the user's chats.
    func talkLines() async -> [TalkLine] {
        let sources: [(sender: ChatTurn.Sender, history: ChatHistory?, folder: URL?)] = prefs.imps.map { profile in
            let sender = ChatTurn.Sender(id: profile.id, name: profile.name, hue: profile.hue)
            if let live = imp(profile.id) { return (sender, live.history, nil) }
            return (sender, nil, persists ? ChatHistory.folder(for: profile.id) : nil)
        }
        let samples = sampleTalks
        let found = await Task.detached(priority: .userInitiated) {
            var seen = Set<UUID>()
            return sources.flatMap { source -> [TalkLine] in
                guard let history = source.history ?? source.folder.map({ ChatHistory(folder: $0) }) else { return [] }
                let chats = history.chats.compactMap { history.chat($0.id) } + [history.current]
                return TalkLog.lines(answeredBy: source.sender, in: chats)
            }
            .filter { seen.insert($0.id).inserted }
        }.value
        return samples + found
    }
}
