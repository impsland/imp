import Foundation
import ImpCore

/// Turns what the user handed over into the user turn the model sees. A picture travels twice:
/// attached (so a model that can see, sees it) and as a file path (so its commands can work on it).
public enum Briefing {
    /// Where it works and how replies are shown, added to every Imp's personality (which the
    /// user writes). `{workspace}` becomes the Imp's own folder (`ImpProfile.systemPrompt`).
    public static let display = """
    Your workspace folder is {workspace}. Your commands start there. Save files you make (pictures, \
    audio, documents…) in it unless the user names another place, and give tools that write files \
    a full path inside it. Relative paths in your replies are read from there.

    Your replies appear in a speech bubble that renders Markdown. To show a picture, audio or video \
    file (a path or URL), embed it like an image: ![what it is](path/to/file). Audio (mp3, m4a, wav…) \
    and video (mp4, mov) get a player. Add #autoplay to the file to play it at once: ![reply](voice.mp3#autoplay). Several marked files play one after another, in the order you wrote them.

    You're a little animated character on the user's desktop. When you have the tools for it, show how \
    you feel with your animations, move around now and then, and when the user wants something to \
    happen by itself (on keys, a click, or when something happens on the Mac), set it up yourself with \
    a trigger, and any tool it needs, rather than explaining how. Ask first if the request is unclear.

    If you have the computer_* tools, you can operate other apps: observe first, act in small steps, \
    and verify the result honestly (met or not met) before telling the user it's done.
    """

    /// What an Imp hatched on the iPhone is told besides its personality.
    public static let pocket = """
    You're a little animated character living on the user's iPhone. Your replies appear in a speech \
    bubble that renders Markdown. You can't run commands or touch files, and you can't see the Mac. \
    When you have the tools for it, act out how you feel with your animations, use the tools you were \
    given, and message the user's other Imps to ask them things.
    """

    /// Said to the model when it has no tools because the request comes from `device`, which `home`
    /// (where it thinks) doesn't count as its owner's: so it doesn't pretend otherwise, and a user who
    /// owns that device learns how to change it.
    public static func untrusted(device: String, home: String) -> String {
        "This request comes from \(device), which is not marked as one of your owner's own devices, so you have no tools for it: "
            + "no commands, no messages to other Imps, nothing that acts. Just talk. If it asks for something that needs "
            + "them, say plainly that you can't use your tools for \(device), and that if \(device) is theirs they can turn on Mine "
            + "for it in the Devices settings on \(home)."
    }

    /// A shortcut: its instruction, applied to what was on the clipboard (or alone, without a clip).
    public static func shortcut(_ prompt: String, clip: Clip?, imagePath: String? = nil) -> ChatMessage {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch clip {
        case nil:
            return .user(task.isEmpty ? "Hi!" : task)
        case .text(let text)?:
            let ask = task.isEmpty ? "Here's something I copied. Respond to it helpfully." : task
            return .user("\(ask)\n\nCopied text:\n\"\"\"\n\(text)\n\"\"\"")
        case .image(let image)?:
            let ask = task.isEmpty ? "Here's a picture I copied. Respond to it helpfully." : task
            return .user("\(ask)\n\n\(note(imagePath))", images: [image])
        }
    }

    /// A trigger went off on its own (the Mac did something, not the user): its instruction, what
    /// happened, and what was copied if it hands that over.
    public static func trigger(_ prompt: String, name: String, happened: String, clip: Clip?, imagePath: String? = nil) -> ChatMessage {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = "(Not typed by the user: your trigger “\(name)” went off. \(happened))"
        var message = shortcut(task.isEmpty ? "Respond to this in your own way." : task, clip: clip, imagePath: imagePath)
        message.content = [message.content ?? "", note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return message
    }

    /// Another Imp of the troupe sent a message (`imp_message`): its answer goes back to it. `place` says where it is.
    /// The words are the core's (`troupe::message_turn`), so an Imp is told the same on every device.
    public static func message(from sender: String, _ text: String, place: String = "on the desktop") -> ChatMessage {
        .user(ImpCore.troupeMessageTurn(sender: sender, text: text, place: place))
    }

    /// Stands for the Imp's workspace folder in its instructions.
    public static let workspaceToken = "{workspace}"

    /// Something the user typed or said, with a picture they pasted, if any.
    public static func message(_ words: String, image: EncodedImage? = nil, imagePath: String? = nil) -> ChatMessage {
        guard let image else { return .user(words) }
        let ask = words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "What do you make of this picture?" : words
        return .user("\(ask)\n\n\(note(imagePath))", images: [image])
    }

    /// The same turn as remembered in the conversation: words only (the file stays on disk).
    public static func remembered(_ message: ChatMessage) -> ChatMessage {
        var m = message
        m.images = nil
        return m
    }

    private static func note(_ path: String?) -> String {
        path.map { "(The picture is attached, and saved at \($0).)" } ?? "(The picture is attached.)"
    }
}
