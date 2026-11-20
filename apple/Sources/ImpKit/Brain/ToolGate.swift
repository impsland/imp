import Foundation
import ImpCore

/// What the person answers when an Imp asks to do something its permissions say `ask` about.
public enum PermissionAnswer: Equatable, Sendable {
    /// Allow this once.
    case once
    /// Allow it now and from now on (an `allow` rule is added to the Imp's agent file).
    case always
    case deny
}

/// What is asked: an Imp wants to do `action` on `resource` (`shell` `ls -la`, `mcp` `files/write_file`).
public struct PermissionQuestion: Equatable, Sendable {
    public var imp: String
    public var action: String
    public var resource: String

    public init(imp: String, action: String, resource: String) {
        self.imp = imp; self.action = action; self.resource = resource
    }

    /// `shell ls -la`: how it reads in the refusal the model gets.
    public var what: String { "\(action) \(resource)" }
}

/// Whoever can be asked (the Imp's bubble). An answer that never comes because the work was stopped is `.deny`.
public protocol PermissionAsking: Sendable {
    func ask(_ question: PermissionQuestion) async -> PermissionAnswer
}

/// The permissions at work in the agent loop (`docs/architecture/configuration.md`, "Permissions"): before every
/// tool call the core says what the call is and what the Imp's rules say about it. `deny` refuses with a sentence the
/// model reads, `ask` asks the person (and counts as `deny` where nobody can be asked), `allow` goes on.
/// Always adds an `allow` rule to the Imp's agent file and has the app read the shared configuration again.
public struct ToolGate: Sendable {
    public var imp: String
    public var agent: String
    public var store: SharedConfigStore
    /// Nil where nobody can be asked: an Imp visiting from another device, one answering another device.
    public var asker: PermissionAsking?
    /// Why nobody can be asked, for the refusal the model reads.
    public var unattended: String
    /// Called after an Always was written.
    public var remembered: @Sendable () async -> Void

    public init(imp: String, agent: String, store: SharedConfigStore, asker: PermissionAsking?,
                unattended: String = String(localized: "nobody can be asked here"),
                remembered: @escaping @Sendable () async -> Void = {}) {
        self.imp = imp; self.agent = agent; self.store = store; self.asker = asker
        self.unattended = unattended; self.remembered = remembered
    }

    /// Nil when the call may go on, else the sentence the model (and the step) read.
    public func refusal(toolID: String?, name: String, arguments: String) async -> String? {
        let verdict = store.gate(agent: agent, toolID: toolID, name: name, arguments: arguments)
        let what = "\(verdict.action) \(verdict.resource)"
        switch verdict.effect {
        case .allow:
            return nil
        case .deny:
            return "Not allowed by your permissions: \(what)"
        case .ask:
            guard let asker else {
                return "Not allowed by your permissions: \(what). It needs the person's answer and \(unattended), so it counts as denied."
            }
            switch await asker.ask(PermissionQuestion(imp: imp, action: verdict.action, resource: verdict.resource)) {
            case .once:
                return nil
            case .always:
                try? store.allowAlways(agent: agent, action: verdict.action, resource: verdict.resource)
                await remembered()
                return nil
            case .deny:
                return "Not allowed by your permissions: \(what). The person chose Deny."
            }
        }
    }
}
