import ImpKit

/// Reading another device's code: what is typed, pasted or seen, and how far the link got. A value, so
/// the sheet only shows it (tested in `ImpTests`).
struct LinkJoin: Equatable {
    var text = ""
    private(set) var joining = false
    private(set) var linked: String?
    private(set) var error: String?

    enum Status: Equatable {
        case empty, notALink, ready, joining
        case linked(String)
        case failed(String)
    }

    var invite: LinkInvite? { LinkInvite(string: text) }

    var status: Status {
        if let linked { return .linked(linked) }
        if joining { return .joining }
        if let error { return .failed(error) }
        if text.isEmpty { return .empty }
        return invite == nil ? .notALink : .ready
    }

    /// Link is offered only for an Imp code, and not while a link is joining or after it has linked.
    var canLink: Bool { invite != nil && !joining && linked == nil }
    /// Nothing more can be typed or pasted while linking or once linked.
    var isLocked: Bool { joining || linked != nil }

    /// A code the camera saw: only an Imp code counts, and only while nothing else is going on. Returns
    /// the invite to link with.
    mutating func found(_ code: String) -> LinkInvite? {
        guard !isLocked, let invite = LinkInvite(string: code) else { return nil }
        text = code
        return invite
    }

    /// Takes pasted text as it is, or else the first Imp code read off a picture. Sets an error when there is neither.
    mutating func paste(text pasted: String?, codes: [String]) {
        error = nil
        if let pasted = pasted?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
            text = pasted
        } else if let code = codes.first(where: { LinkInvite(string: $0) != nil }) {
            text = code
        } else {
            error = String(localized: "There's no Imp link or code to paste.")
        }
    }

    mutating func start() { error = nil; joining = true }
    mutating func finish(linked name: String) { joining = false; linked = name }
    mutating func finish(failed message: String) { joining = false; error = message }
}

/// What the code area of the Link sheet shows: waiting for the other device, linked with it (the sheet
/// plays its reward and closes), or a problem. A value, so the sheet only shows it (tested in `ImpTests`).
enum LinkPhase: Equatable {
    case waiting
    case linked(String)
    case failed(String)

    /// A device that appeared in the list, or a code this Mac read, means linked. A problem with the code read
    /// is shown while it lasts.
    init(newcomer: String?, join: LinkJoin) {
        if let newcomer {
            self = .linked(newcomer)
            return
        }
        switch join.status {
        case .linked(let name): self = .linked(name)
        case .failed(let message): self = .failed(message)
        case .notALink: self = .failed(String(localized: "That isn't a link from Imp."))
        case .empty, .ready, .joining: self = .waiting
        }
    }

    var linkedName: String? {
        if case .linked(let name) = self { name } else { nil }
    }

    var problem: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}
