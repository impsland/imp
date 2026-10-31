import ImpKit
import SwiftUI

/// Whether an Imp can take a message right now.
enum ChatAvailability {
    case ready
    /// Its brain is on a Mac that isn't connected.
    case offline
    /// A pocket Imp with no service and model to think with.
    case noBrain
}

/// Where a chat lives: the Mac (its Imps think there) or this iPhone (pocket Imps). The chat sheet
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

extension LinkClient: ChatSource {
    var restingStatus: String { String(localized: "Ready") }
    func imp(_ id: UUID) -> LinkImp? { imps.first { $0.id == id } }
    func turns(_ id: UUID) -> [LinkTurn] { chats[id] ?? [] }
    func working(_ id: UUID) -> LinkWork? { work[id] }
    func mood(_ id: UUID) -> Mood? { moods[id] }
    func availability(_ id: UUID) -> ChatAvailability { isConnected ? .ready : .offline }

    /// Everyone this Imp can message: the other Imps on this phone and the ones still on the Mac.
    func peers(_ id: UUID) -> [LinkImp] {
        guard isConnected else { return [] }
        var seen: Set<String> = [imp(id)?.name.lowercased() ?? ""]
        return (imps + others).filter { $0.id != id && seen.insert($0.name.lowercased()).inserted }
    }

    func intro(_ imp: LinkImp, _ availability: ChatAvailability) -> (title: String, text: String) {
        (String(localized: "Ask \(imp.name) anything"),
         String(localized: "It works on your Mac, with its tools, and can message the Imps there too. Pictures, voices and files it makes show up right here."))
    }

    func newChatNote(_ imp: LinkImp) -> String {
        String(localized: "This chat leaves your phone, but your Mac keeps it: it's in \(imp.name)'s Brain › Memory › Chats. \(imp.name) starts fresh.")
    }
}
