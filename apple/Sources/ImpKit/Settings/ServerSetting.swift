import Foundation

/// One server setting (The Hop) as a value: the choices, the address, and the check.
/// The Devices page shows it through a card, so it is tested once here.
public struct ServerSetting: Equatable, Sendable {
    /// What the card says about the server, one state at a time.
    public enum Status: Equatable, Sendable {
        /// No server: it is off.
        case off
        /// What is typed is not an address: the sentence says why.
        case problem(String)
        /// The address in use, not checked yet.
        case ready(String)
        /// The check is running.
        case checking(String)
        /// The last check reached it, or could not.
        case reachable(String)
        case unreachable(String)
    }

    public let kind: ServerKind
    /// The address as stored: empty is off.
    public private(set) var text: String
    /// Custom was picked, even while the typed address happens to match a preset.
    private var custom: Bool
    /// The address the last check was for, and what it found (nil while it runs).
    private var check: (address: String, ok: Bool?)?

    public init(kind: ServerKind, text: String) {
        self.kind = kind
        self.text = text
        custom = ServerChoice.of(text, kind) == .custom
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.text == b.text && a.custom == b.custom && a.check?.address == b.check?.address && a.check?.ok == b.check?.ok
    }

    /// The picked choice.
    public var choice: ServerChoice { custom ? .custom : ServerChoice.of(text, kind) }

    /// Whether the address field shows (only for Custom).
    public var showsAddress: Bool { choice == .custom }

    /// The address in use, or nil (off, or not an address).
    public var inUse: String? {
        return HopServer(text)?.address
    }

    public var status: Status {
        if let problem = kind.problem(with: text) { return .problem(problem) }
        guard let address = inUse else { return .off }
        guard let check, check.address == address else { return .ready(address) }
        switch check.ok {
        case nil: return .checking(address)
        case true?: return .reachable(address)
        case false?: return .unreachable(address)
        }
    }

    /// Check is offered for an address in use, and not while one runs.
    public var canCheck: Bool {
        guard inUse != nil else { return false }
        if case .checking = status { return false }
        return true
    }

    /// Picks a choice: a preset fills its address (Off empties it), Custom keeps what was typed unless it
    /// was a preset's address. Returns the text to store.
    @discardableResult
    public mutating func pick(_ option: ServerChoice) -> String {
        custom = option == .custom
        if let address = option.address(kind) {
            text = address
        } else if ServerChoice.of(text, kind) != .custom {
            text = ""
        }
        return text
    }

    /// The person typed an address: what a check found no longer applies.
    public mutating func edit(_ address: String) {
        text = address
        check = nil
    }

    /// Starts a check: returns the address to reach, or nil when there is nothing to check.
    public mutating func startCheck() -> String? {
        guard canCheck, let address = inUse else { return nil }
        check = (address, nil)
        return address
    }

    /// What the check found for `address`. A result for an address that has changed since is dropped.
    public mutating func finishCheck(_ address: String, reachable: Bool) {
        guard check?.address == address, inUse == address else { return }
        check = (address, reachable)
    }
}
