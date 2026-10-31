import ImpKit
import SwiftUI

/// Whether an Imp can take a message right now.
enum ChatAvailability {
    case ready
    /// Its brain is on a device that isn't connected: a visiting Imp sleeps until its home is back.
    case offline
    /// A pocket Imp with no service and model to think with.
    case noBrain
}

/// Where a chat lives: the Imp's home (visiting Imps think there) or this iPhone (pocket Imps). The chat sheet
/// works against either.
@MainActor
protocol ChatSource {
    /// What an idle, available Imp says about itself under its name.
    var restingStatus: String { get }
    func imp(_ id: UUID) -> LinkImp?
    func turns(_ id: UUID) -> [LinkTurn]
    func working(_ id: UUID) -> LinkWork?
    func mood(_ id: UUID) -> Mood?
    func availability(_ id: UUID) -> ChatAvailability
    /// The other Imps it can be asked to message.
    func peers(_ id: UUID) -> [LinkImp]
    func intro(_ imp: LinkImp, _ availability: ChatAvailability) -> (title: String, text: String)
    func newChatNote(_ imp: LinkImp) -> String
    func ask(_ id: UUID, _ text: String)
    func stop(_ id: UUID)
    func newChat(_ id: UUID)
}

extension LinkHub: ChatSource {
    var restingStatus: String { String(localized: "Ready") }
    func imp(_ id: UUID) -> LinkImp? { visit(id)?.imp }
    func turns(_ id: UUID) -> [LinkTurn] { chats[id] ?? [] }
    func working(_ id: UUID) -> LinkWork? { work[id] }
    func mood(_ id: UUID) -> Mood? { moods[id] }
    func availability(_ id: UUID) -> ChatAvailability { isAwake(id) ? .ready : .offline }

    /// Everyone this visiting Imp can message: the Imps on this screen and on its home's.
    func peers(_ id: UUID) -> [LinkImp] {
        guard isAwake(id), let home = visit(id)?.home.id else { return [] }
        var seen: Set<String> = [imp(id)?.name.lowercased() ?? ""]
        return LinkTalks.targets(of: id, mine: node.stage(of: home), stage: staged).map(\.imp)
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    func intro(_ imp: LinkImp, _ availability: ChatAvailability) -> (title: String, text: String) {
        let home = visit(imp.id)?.home.device.name ?? String(localized: "its home")
        if availability == .offline {
            return (String(localized: "\(imp.name) is asleep"), String(localized: "\(home) is away. It wakes when \(home) is back."))
        }
        return (String(localized: "Ask \(imp.name) anything"),
                String(localized: "It works on \(home), with its tools, and can message the Imps there too. Pictures, voices and files it makes show up right here."))
    }

    func newChatNote(_ imp: LinkImp) -> String {
        guard let home = visit(imp.id)?.home.device else { return String(localized: "\(imp.name) starts fresh.") }
        return home.kind == .mac
            ? String(localized: "This chat leaves your phone, but \(home.name) keeps it: it's in \(imp.name)'s Brain › Memory › Chats. \(imp.name) starts fresh.")
            : String(localized: "This chat leaves your phone, but \(home.name) keeps it. \(imp.name) starts fresh.")
    }
}
