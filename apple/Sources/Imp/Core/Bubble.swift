import Foundation
import ImpDesign
import ImpKit

/// What Imp is saying: the speech bubble's content.
struct Bubble: Equatable, Identifiable {
    enum Phase: Equatable { case listening, typing, thinking, result, error, hint, chat }
    enum Link: Equatable { case settings, wake }

    /// One visible piece of work: a command or tool call, waking the tools up.
    struct Step: Equatable, Identifiable {
        enum State: Equatable { case running, done, failed }
        var id = UUID()
        var icon: String
        var title: String
        var state = State.running
        /// The tool this step runs (to match its end), if it's a tool call.
        var tool: String?
        /// What was asked (the command, or the tool's arguments) and what came back (nil while running).
        var request = ""
        var response: String?
        /// The model thinking: `response` is its reasoning (live while running), `seconds` how long it took once done.
        var thought = false
        var seconds: Int?

        /// What a click opens: a tool call's request and response, or a thought's reasoning.
        var isExpandable: Bool { tool != nil || thought }

        /// The most of a response kept for showing (outputs can be huge, the model got it all).
        static let responseLimit = 20_000
        static func clipped(_ response: String) -> String {
            response.count > responseLimit ? response.prefix(responseLimit) + "\n… (\(response.count - responseLimit) more characters)" : response
        }

        /// A step from the history (its id kept, so it opens and closes like a live one).
        init(_ saved: ChatTurn.Step) {
            self.init(id: saved.id, icon: saved.icon, title: saved.title, state: saved.failed ? .failed : .done,
                      tool: saved.isThought ? nil : "saved", request: saved.request, response: saved.response)
            thought = saved.isThought
            seconds = saved.seconds
        }

        /// The model is thinking: its reasoning shows as it streams in.
        static func thinking(_ reasoning: String) -> Step {
            var step = Step(icon: ChatTurn.Step.thoughtIcon, title: ChatTurn.Step.thinkingTitle, response: reasoning)
            step.thought = true
            return step
        }

        init(id: UUID = UUID(), icon: String, title: String, state: State = .running, tool: String? = nil,
             request: String = "", response: String? = nil) {
            self.id = id; self.icon = icon; self.title = title; self.state = state; self.tool = tool
            self.request = request; self.response = response
        }

        /// As kept in the history. Only tool calls are worth keeping (not "Waking up tools").
        var saved: ChatTurn.Step? {
            if thought {
                guard let seconds else { return nil }
                return ChatTurn.Step(id: id, icon: icon, title: title, request: request, response: response, failed: false, seconds: seconds)
            }
            guard tool != nil else { return nil }
            return ChatTurn.Step(id: id, icon: icon, title: title, request: request, response: response, failed: state == .failed)
        }

        /// MCP servers still starting up (done once real work starts).
        static var wakingUp: Step { Step(icon: "powerplug", title: String(localized: "Waking up tools")) }
    }

    /// One Imp talking to another (`imp_message`): who, in whose colour, and the question. The
    /// bubble shows it as a header chip in the other Imp's colour and the question quoted.
    struct Exchange: Equatable {
        enum Role: Equatable {
            /// This Imp is thinking about a question another Imp asked ("Pip asks").
            case asked
            /// This Imp's answer to that question ("Reply to Pip").
            case reply
            /// This Imp waits for another Imp's answer to its question ("Asking Mo…").
            case asking
            /// This Imp's turn that begins with the answer to a message it sent without waiting ("Bo answered").
            case answered
        }
        var role: Role
        /// The other Imp (the asker, or the one asked), with its colour.
        var peer: ChatTurn.Sender
        var question: String

        /// The same exchange, as the answer to it.
        var asReply: Exchange { Exchange(role: .reply, peer: peer, question: question) }
    }

    /// A question the Imp's permissions ask the person before a tool call goes on: what it wants to do and to what.
    /// Shown in a fixed-height block of the working bubble (the resource on one line, in full as its help).
    struct Prompt: Equatable {
        var action: String
        var resource: String
        /// Questions queued behind this one.
        var more = 0

        /// The symbol of what is asked: a command, a tool, a file, another Imp.
        var icon: String {
            switch action {
            case "shell": "terminal"
            case "mcp": "powerplug"
            case "read": "doc.text"
            case "edit": "square.and.pencil"
            case "message": "bubble.left.and.bubble.right"
            case "skill": "sparkles"
            case "computer": "cursorarrow.click"
            default: "hand.raised"
            }
        }
    }

    var id = UUID()
    /// What this is about (an action's name). Shown small and quiet, never as a header.
    var title = ""
    var text = ""
    var phase: Phase
    /// Typing: the field's placeholder ("Ask Imp anything…", "I didn't catch that…").
    var prompt: String?
    var steps: [Step] = []
    /// Typing: a picture pasted into the text box, sent with the message.
    var attachment: EncodedImage?
    var link: Link?
    /// The answer is still arriving (streamed): no buttons yet.
    var isStreaming = false
    /// Set while this bubble is about a talk with another Imp.
    var exchange: Exchange?
    /// The question waiting for an answer (working and chat bubbles only: the model keeps it there).
    var permission: Prompt?

    /// A finished answer with words: it can be copied.
    var isCopyable: Bool { phase == .result && !isStreaming && !text.isEmpty }
}

extension Bubble.Link {
    /// The button's words. `name` is the Imp that says it.
    func title(for name: String) -> String {
        switch self {
        case .settings: String(localized: "Open Settings")
        case .wake: words("firstrun.wake", name)
        }
    }
}

/// What Imp is busy with. Drives its pose, the glyph over its head and the bubble.
enum Activity: Equatable {
    case listening, typing, thinking, tools

    var mood: Mood {
        switch self {
        case .listening, .typing: .listening
        case .thinking: .thinking
        case .tools: .working
        }
    }

    /// The bubble an activity that waits for the user lives in (a text box, the listening
    /// bubble). Nil for work the Imp does on its own.
    var waitingPhase: Bubble.Phase? {
        switch self {
        case .typing: .typing
        case .listening: .listening
        case .thinking, .tools: nil
        }
    }

    var glyph: Glyph? {
        switch self {
        case .tools: .gear
        default: nil
        }
    }
}

/// A little mischief while an Imp works: short, so it never fights the title for room.
enum Captions {
    static let thinking = [String(localized: "Bribing the server…"), String(localized: "Poking the cloud…"), String(localized: "Summoning answers…"), String(localized: "Sharpening horns…"),
                           String(localized: "Cutting in line…"), String(localized: "Stirring the cauldron…"), String(localized: "Shaking the oracle…"), String(localized: "Pulling some strings…"),
                           String(localized: "Tickling the GPUs…"), String(localized: "Haggling for tokens…"), String(localized: "Plotting quietly…"), String(localized: "Borrowing a brain…")]
}
