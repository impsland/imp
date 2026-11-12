import Foundation

/// The animation catalog: `spec/animations/catalog.json`, the one place animations are defined.
/// The Den offers every entry; the apps carry only the ones marked `"bundled": true`, copied into
/// `AnimationCatalog.generated.swift` by `node design/generate.mjs` (no hand copy), and read here.
public enum AnimationCatalog {
    /// One animation of the catalog.
    public struct Entry: Hashable, Sendable {
        public var id: String
        public var name: String
        public var about: String
        /// What starts it out of the box.
        public var starts: Set<AnimationTrigger>
        public var beats: [AnimationBeat]
    }

    private static let bundledData = Data(bundledJSON.utf8)

    /// The animations bundled with the apps, in catalog order.
    public static let bundled: [Entry] = parse(bundledData)

    /// The bundled animation that starts each gesture out of the box (`defaults` in the catalog).
    public static let defaults: [AnimationTrigger: String] = parseDefaults(bundledData)

    /// The `defaults` of a catalog file: a trigger and the id of the animation that starts it.
    public static func parseDefaults(_ data: Data) -> [AnimationTrigger: String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let map)? = root["defaults"] else { return [:] }
        var out: [AnimationTrigger: String] = [:]
        for (key, value) in map { if let t = AnimationTrigger(rawValue: key), let id = value.string { out[t] = id } }
        return out
    }

    public static func entry(_ id: String) -> Entry? { bundled.first { $0.id == id } }

    /// An animation that isn't there plays nothing (never happens while the bundle is intact).
    static func missing(_ id: String) -> Entry { Entry(id: id, name: id, about: "", starts: [], beats: []) }

    /// The animations of a catalog file (the whole one or the bundled part), those that are `only` bundled or all.
    public static func parse(_ data: Data, onlyBundled: Bool = false) -> [Entry] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), let list = root["animations"]?.array else { return [] }
        var out: [Entry] = []
        for item in list {
            guard let id = item["id"]?.string, let name = item["name"]?.string, let beats = item["beats"]?.array else { continue }
            if onlyBundled && item["bundled"]?.bool != true { continue }
            var problems: [String] = []
            let starts = Set((item["starts"]?.array ?? []).compactMap { $0.string.flatMap(AnimationTrigger.init(rawValue:)) })
            out.append(Entry(id: id, name: name, about: item["about"]?.string ?? "", starts: starts,
                             beats: beats.compactMap { AnimationBeat(kit: $0, problems: &problems) }))
        }
        return out
    }
}
