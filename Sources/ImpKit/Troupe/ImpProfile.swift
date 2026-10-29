import CoreGraphics
import Foundation

/// One Imp of the troupe: how it looks, who it is, which model and tools it uses.
public struct ImpProfile: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Activated: the Imp lives on the desktop (its own floating window, its shortcuts work).
    /// Deactivated: it waits in the app's window.
    public var isActive = true
    /// Skin colour as a hue (0…1). Red is 0.
    public var hue: Double
    /// The colour it secretly loves (a hue). Nobody tells you: pick it and you'll see.
    public var favoriteHue: Double
    /// You found its favourite colour (the swatch gets a little heart from then on).
    public var knowsFavorite = false
    public var scale = 1.0
    /// Who this Imp is: the first part of the system prompt for conversations with it.
    public var personality: String
    /// The rest of the system prompt: how its replies are shown (Markdown, pictures, players).
    /// `nil` follows the built-in text (`Briefing.display`, which may improve in later versions);
    /// an empty string sends the personality alone.
    public var instructions: String?
    /// Sends the tools it called, and what they returned, with the rest of the chat. `nil` is
    /// on (optional, so profiles saved before it existed still load).
    public var sendsToolCalls: Bool?
    /// How many recent exchanges of the chat it's sent. `nil`: `ChatMemory.defaultExchanges`.
    public var exchangesSent: Int?
    /// Its models. `nil` uses the template brain (`AIConfig.brain`).
    public var brain: Brain?
    /// Where it sits on screen (bottom-left of its panel). `nil` until placed.
    public var origin: CGPoint?
    /// MCP servers (from `ImpPreferences.mcpServers`) whose tools this Imp may use.
    public var servers: [UUID] = []
    /// May run commands on this Mac (the `shell` tool): on by default, it's how an Imp does things.
    public var usesShell = true
    /// Its own tools it may not use. Groups that are on by default stay on until listed here.
    /// Optional, so older profiles load.
    private var ownToolsOff: [ImpToolGroup]?
    /// Its own tools that are off by default (`ImpToolGroup.isOnByDefault`) and it may use.
    private var ownToolsOn: [ImpToolGroup]?
    /// Storage for `animations` and `traits` (optional, so older profiles load).
    var ownAnimations: [MadeAnimation]?
    var character: ImpTraits?

    /// Whether it may use one group of its own tools (animations, its senses, setting itself up…).
    public func uses(_ group: ImpToolGroup) -> Bool {
        group.isOnByDefault ? !(ownToolsOff ?? []).contains(group) : (ownToolsOn ?? []).contains(group)
    }

    public mutating func setUses(_ group: ImpToolGroup, _ on: Bool) {
        func update(_ list: [ImpToolGroup]?, _ member: Bool) -> [ImpToolGroup]? {
            var set = Set(list ?? [])
            if member { set.insert(group) } else { set.remove(group) }
            return set.isEmpty ? nil : ImpToolGroup.allCases.filter(set.contains)
        }
        if group.isOnByDefault { ownToolsOff = update(ownToolsOff, !on) } else { ownToolsOn = update(ownToolsOn, on) }
    }

    /// The groups of its own tools it may use.
    public var ownTools: Set<ImpToolGroup> { Set(ImpToolGroup.allCases.filter(uses)) }

    public init(id: UUID = UUID(), name: String, hue: Double, favoriteHue: Double, scale: Double = 1,
                personality: String, brain: Brain? = nil) {
        self.id = id; self.name = name; self.hue = hue; self.favoriteHue = favoriteHue; self.scale = scale
        self.personality = personality; self.brain = brain
    }

    /// The instructions in effect: the user's own, or the built-in ones.
    public var effectiveInstructions: String { instructions ?? Briefing.display }

    public var remembersToolCalls: Bool { sendsToolCalls ?? true }
    public var memoryExchanges: Int { max(exchangesSent ?? ChatMemory.defaultExchanges, 1) }

    /// Its own folder (see `Workspace`).
    public var workspace: URL { Workspace.directory(for: id) }

    /// Everything the model is told about this Imp before the conversation: its personality,
    /// then the instructions (either may be empty), with `{workspace}` filled in.
    public var systemPrompt: String {
        [personality, effectiveInstructions.replacingOccurrences(of: Briefing.workspaceToken, with: workspace.path)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// A stable identity for the first Imp.
    public static let defaultID = UUID(uuidString: "1A1A1A1A-0000-4000-8000-00000000F00D")!

    /// Our little red Imp. Red is its favourite colour too.
    public static var imp: ImpProfile {
        ImpProfile(id: defaultID, name: "Imp", hue: defaultHue, favoriteHue: defaultHue, personality: Persona.imp)
    }

    /// Every Imp hatches red.
    public static let defaultHue = 0.0

    /// A newcomer: red like everyone, a name and a fresh personality to edit, and a secret
    /// favourite colour (never red: that would give it away).
    public static func newcomer(joining troupe: [ImpProfile]) -> ImpProfile {
        let name = randomName(avoiding: troupe.map(\.name), random: false)
        let favorite = colors.filter { $0.hue != defaultHue }.randomElement()!.hue
        return ImpProfile(name: name, hue: defaultHue, favoriteHue: favorite, personality: Persona.newcomer(named: name))
    }

    /// Is `hue` its favourite? Close enough counts, so the "any shade" slider can find it too.
    public func isFavorite(_ hue: Double) -> Bool { Self.hueDistance(hue, favoriteHue) < Self.favoriteTolerance }

    public static let favoriteTolerance = 0.02

    /// Distance between two hues around the colour wheel (0…0.5).
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// A name nobody in the troupe has yet: random from the pool, or the first free one.
    public static func randomName(avoiding used: [String], random: Bool = true) -> String {
        let lower = Set(used.map { $0.lowercased() })
        let free = names.filter { !lower.contains($0.lowercased()) }
        if let n = random ? free.randomElement() : free.first { return n }
        var i = used.count + 1
        while lower.contains("imp \(i)") { i += 1 }
        return "Imp \(i)"
    }

    static let names = ["Pip", "Nib", "Tock", "Mote", "Fizz", "Bram", "Quill", "Dot", "Sprocket", "Wick", "Juniper",
                        "Biscuit", "Ziggy", "Pebble", "Clove", "Moxie", "Tinder", "Noodle", "Zest", "Gizmo", "Ember", "Truffle",
                        "Cinder", "Bumble", "Smudge", "Pickle", "Fennel", "Kettle", "Mochi", "Sorrel", "Widget", "Puck"]

    /// Skin colours to choose from.
    public static let colors: [(name: String, hue: Double)] = [
        (String(localized: "Red"), 0), (String(localized: "Tangerine"), 0.07), (String(localized: "Gold"), 0.12), (String(localized: "Lime"), 0.25), (String(localized: "Mint"), 0.42),
        (String(localized: "Teal"), 0.5), (String(localized: "Sky"), 0.57), (String(localized: "Indigo"), 0.67), (String(localized: "Violet"), 0.76), (String(localized: "Pink"), 0.9),
    ]
}
