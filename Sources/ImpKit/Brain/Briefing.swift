import Foundation

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
    and video (mp4, mov) get a player. Add #autoplay to the file to play it at once: ![reply](voice.mp3#autoplay).
    """

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
