import Foundation

/// How much a connected device is trusted (see "Handshake" in `docs/LINK.md`).
public enum LinkStanding: String, Codable, Sendable, Equatable {
    /// A device this one has a link with: both pinned each other's key.
    case peer
    /// Anyone else who knows the door key. It may only claim and use tickets.
    case visitor
}

/// What a message from a connected device may do here. Pure, so every rule can be tested. The home
/// answers an Imp's requests only from its current holder, and a holder only believes what its Imp's
/// home says about that Imp.
public enum LinkAccess {
    public static func allows(_ message: LinkMessage, from device: UUID, standing: LinkStanding,
                              ledger: AwayLedger, visits: Visits) -> Bool {
        switch message {
        case .ping, .pong, .bye, .claim, .release, .claimed, .gone, .answer:
            // Claims and releases prove themselves with a ticket; `claimed` and `gone` only ever
            // touch a visit of the sender's own; an answer must match a question sent to the sender.
            return true
        case .hello, .welcome:
            // Only the handshake, which the node deals with before any of this.
            return false
        case .ask(let imp, _), .stop(let imp), .newChat(let imp), .felt(let imp, _), .file(_, let imp, _), .talks(let imp):
            return ledger.authorises(device, for: imp)
        case .message(_, _, let target, _, _, _):
            // A visitor holds the target's body: that is its right to ask it something.
            return standing == .peer || ledger.authorises(device, for: target)
        case .routes, .stage, .pass, .took, .declined, .adopt, .adopted:
            return standing == .peer
        case .look(let imp):
            return visits.visit(of: imp.id)?.home.id == device
        case .chat(let imp, _), .work(let imp, _), .mood(let imp, _), .animate(let imp, _),
             .speech(let imp, _), .talkLines(let imp, _):
            return visits.visit(of: imp)?.home.id == device
        case .filePart, .fileFailed:
            return visits.visits.contains { $0.home.id == device }
        }
    }
}
