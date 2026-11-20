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
    /// What it is good at, in a line or two: the other Imps read it to know whom to ask. `nil`: not said
    /// (optional, so older profiles load). Cut to `maxAboutLength` when it is used (`troupeAboutLine`).
    public var about: String?
    /// The rest of the system prompt: how its replies are shown (Markdown, pictures, players).
    /// `nil` follows the built-in text (`Briefing.display`, which may improve in later versions).
    /// An empty string sends the personality alone.
    public var instructions: String?
    /// Sends the tools it called, and what they returned, with the rest of the chat. `nil` is
    /// on (optional, so profiles saved before it existed still load).
    public var sendsToolCalls: Bool?
    /// How many recent exchanges of the chat it's sent. `nil`: no limit (`ChatMemory.noLimit`).
    public var exchangesSent: Int?
    /// The size of a chat, in tokens (estimated, about four characters each), at which a new chat or a
    /// recap is suggested. `nil`: `newChatDefault`. One of `newChatChoices`.
    public var newChatAtTokens: Int?
    /// Its models. `nil` uses the template brain (`AIConfig.brain`).
    public var brain: Brain?
    /// Where it sits on screen (bottom-left of its panel). `nil` until placed.
    public var origin: CGPoint?
    /// The iPhone it was tossed onto (that phone's id, see `LinkRequest.hello`). It's still out
    /// and still thinks on this Mac, but its body is on the phone, so the desktop doesn't show it.
    /// `nil`: here on the Mac.
    public var awayOn: UUID?
    /// MCP servers (from `ImpPreferences.mcpServers`) whose tools this Imp may use.
    public var servers: [UUID] = []
    /// May run commands on this Mac (the `shell` tool): on by default, it's how an Imp does things.
    public var usesShell = true
    /// Its own tools it may not use. Groups that are on by default stay on until listed here.
    /// Optional, so older profiles load.
    /// Stored as the groups' names, so a group that no longer exists (the old "den") is skipped, not fatal.
    private var ownToolsOff: [String]?
    /// Its own tools that are off by default (`ImpToolGroup.isOnByDefault`) and it may use.
    private var ownToolsOn: [String]?
    /// Single tools switched off, by registry id (`own.personality.imp_message`, `mcp.files.read_file`).
    /// Optional, so older profiles load. Whole groups are `ownToolsOff` and `servers`.
    private var toolsOff: [String]?
    /// What was written over single tools' names and descriptions, by registry id. Optional, so older profiles load.
    private var toolTexts: [String: ToolText]?
    /// Storage for `animations` and `traits` (optional, so older profiles load).
    var ownAnimations: [MadeAnimation]?
    var character: ImpTraits?
    /// Whether it may use one group of its own tools (animations, its senses, setting itself up…).
    public func uses(_ group: ImpToolGroup) -> Bool {
        group.isOnByDefault ? !(ownToolsOff ?? []).contains(group.rawValue) : (ownToolsOn ?? []).contains(group.rawValue)
    }

    public mutating func setUses(_ group: ImpToolGroup, _ on: Bool) {
        func update(_ list: [String]?, _ member: Bool) -> [String]? {
            var set = Set(list ?? [])
            if member { set.insert(group.rawValue) } else { set.remove(group.rawValue) }
            return set.isEmpty ? nil : ImpToolGroup.allCases.map(\.rawValue).filter(set.contains)
        }
        if group.isOnByDefault { ownToolsOff = update(ownToolsOff, !on) } else { ownToolsOn = update(ownToolsOn, on) }
    }

    /// Whether one tool (by registry id) is not switched off for it.
    public func uses(tool id: String) -> Bool { !(toolsOff ?? []).contains(id) }

    public mutating func setUses(tool id: String, _ on: Bool) {
        var set = Set(toolsOff ?? [])
        if on { set.remove(id) } else { set.insert(id) }
        toolsOff = set.isEmpty ? nil : set.sorted()
    }

    /// What was written over how its tools read to the model, by registry id (see `ToolText`).
    public var toolText: [String: ToolText] {
        get { toolTexts ?? [:] }
        set { toolTexts = newValue.filter { !$0.value.isEmpty }.isEmpty ? nil : newValue.filter { !$0.value.isEmpty } }
    }

    /// The single tools switched off for it, by registry id.
    public var disabledTools: Set<String> { Set(toolsOff ?? []) }

    /// What is switched off for it, as `ToolSet` applies it. A group of an MCP server is on when the
    /// server is in `servers`, which `MCPScope` already takes care of.
    public var toolSelection: ToolSelection {
        ToolSelection(groupsOff: Set(ImpToolGroup.allCases.filter { !uses($0) }.map(ToolRegistry.ownGroupID)), toolsOff: disabledTools, text: toolText)
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

    public static let maxAboutLength = 200

    public var remembersToolCalls: Bool { sendsToolCalls ?? true }
    /// The size at which a long chat gets a gentle suggestion to recap it or start a new one.
    public var newChatAt: Int { newChatAtTokens.flatMap { Self.newChatChoices.contains($0) ? $0 : nil } ?? Self.newChatDefault }
    /// The core's thresholds (`memory::NOTICE_CHOICES`), shared with the command line app's `long_chat_tokens`.
    public static let newChatChoices = ChatMemory.rules.noticeChoices.map(Int.init)
    public static let newChatDefault = Int(ChatMemory.rules.noticeDefaultTokens)
    public var memoryExchanges: Int { exchangesSent.map { max($0, 1) } ?? ChatMemory.noLimit }

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

    /// The name of the first Imp, on the Mac and on the iPhone.
    public static let firstName = "Pip"

    /// A stable identity for the first Imp.
    public static let defaultID = UUID(uuidString: "1A1A1A1A-0000-4000-8000-00000000F00D")!

    /// Our little red Imp, Pip. Red is its favourite colour too. Not called "Imp", so it is never confused with the app.
    public static var imp: ImpProfile {
        ImpProfile(id: defaultID, name: firstName, hue: defaultHue, favoriteHue: defaultHue, personality: Persona.imp)
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

    /// A name nobody in the troupe has yet: random from the pool, or the first free one. Once every name is
    /// taken, a pool name with a number (`Pip 2`). Never "Imp": that is the app.
    public static func randomName(avoiding used: [String], random: Bool = true) -> String {
        let lower = Set(used.map { $0.lowercased() })
        let free = names.filter { !lower.contains($0.lowercased()) }
        if let n = random ? free.randomElement() : free.first { return n }
        for i in 2... {
            if let n = names.first(where: { !lower.contains("\($0.lowercased()) \(i)") }) { return "\(n) \(i)" }
        }
        return names[0]
    }

    /// Short, cute names that sound about the same in most languages: mostly open syllables ending in a vowel,
    /// none that means something rude or is a brand in a language we know of. Pip comes first: it's the first Imp.
    static let names = ["Pip", "Dot", "Biscuit", "Mochi", "Momo", "Coco", "Lulu", "Nori", "Miso", "Tofu", "Yuzu",
                        "Kiwi", "Mango", "Zuzu", "Pebble", "Noodle", "Bumble", "Pickle", "Ziggy", "Fizz", "Nib", "Puck",
                        "Gizmo", "Ember", "Bean", "Button", "Muffin", "Peanut", "Waffle", "Toffee", "Poppy", "Sunny"]

    /// Skin colours to choose from.
    public static let colors: [(name: String, hue: Double)] = [
        (String(localized: "Red"), 0), (String(localized: "Tangerine"), 0.07), (String(localized: "Gold"), 0.12), (String(localized: "Lime"), 0.25), (String(localized: "Mint"), 0.42),
        (String(localized: "Teal"), 0.5), (String(localized: "Sky"), 0.57), (String(localized: "Indigo"), 0.67), (String(localized: "Violet"), 0.76), (String(localized: "Pink"), 0.9),
    ]
}
