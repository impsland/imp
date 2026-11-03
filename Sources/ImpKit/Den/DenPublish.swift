import Foundation

/// Getting a kit ready for the Den: what is public, what is left out, and the name it goes under.
/// A published kit is read by everyone, so it never carries chats, memory, keys or the model an Imp
/// thinks with.
public enum DenPublish {
    public static let maxSummary = 120
    public static let maxTags = 5

    /// The kit as it goes public: Imps without their model settings and chats. Tools (MCP servers)
    /// stay, since sharing them is the point of a tool package, and the review on the other side
    /// lists every command they would run.
    public static func publicKit(_ kit: Kit) -> Kit {
        var out = kit
        for i in out.imps.indices {
            out.imps[i].brain = nil
            out.imps[i].chats = []
        }
        return out
    }

    /// A slug from the kit's name (empty when nothing usable is left).
    public static func suggestedSlug(for kit: Kit) -> String {
        DenName.slug(kit.name.isEmpty ? (kit.imps.first?.name ?? kit.animations.first?.title ?? kit.triggers.first?.name ?? "") : kit.name)
    }

    /// Tags as the Den wants them: lowercase slugs, no repeats, at most `maxTags`.
    public static func tags(_ input: [String]) -> [String] {
        var tags: [String] = []
        for tag in input.map({ DenName.slug($0, limit: 24) }) where !tag.isEmpty && !tags.contains(tag) { tags.append(tag) }
        return Array(tags.prefix(maxTags))
    }

    /// The text to upload, or why it can't be.
    public static func text(of kit: Kit) throws -> String {
        let text = publicKit(kit).json(pretty: false)
        guard text.utf8.count <= Kit.maxBytes else {
            throw DenError(status: 0, title: String(localized: "That's too big to share (\(Kit.maxBytes / 1024) KB at most)."))
        }
        return text
    }
}
