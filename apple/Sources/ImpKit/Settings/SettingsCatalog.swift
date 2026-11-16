import Foundation

/// A page of settings: one of the app-wide groups or one of an Imp's own pages. The raw value is the name
/// a tool or a link uses.
public enum SettingsPlace: String, CaseIterable, Sendable {
    case app, bubble, talking, brains, devices, sharing, animations, privacy, backup
    case brain, personality, look, tools, triggers, moves

    /// The app-wide group this page is, if it is one.
    public var group: SettingsGroup? { SettingsGroup(rawValue: rawValue) }
    /// Whether the page belongs to one Imp.
    public var isPerImp: Bool { group == nil }

    /// The page a tool or a link means by this name ("looks" is the look).
    public init?(name: String) {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        self.init(rawValue: lowered == "looks" ? "look" : lowered)
    }

    public var titleKey: String {
        if let group { return "settings.group.\(group.rawValue)" }
        return "imp_settings.marker.\(rawValue)"
    }

    public var symbol: String {
        switch self {
        case .brain: "lightbulb.fill"
        case .look: "paintpalette.fill"
        case .personality: "theatermasks.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .triggers: "bolt.fill"
        case .moves: "figure.dance"
        default: group?.symbol ?? "gearshape"
        }
    }

    /// The phone has these pages. The others are on the Mac only.
    public var onPhone: Bool {
        switch self {
        case .app, .talking, .brains, .devices, .sharing, .animations, .brain, .personality, .look, .tools: true
        case .bubble, .privacy, .backup, .triggers, .moves: false
        }
    }

    /// The settings on this page, in reading order.
    public var settings: [SettingID] { SettingID.allCases.filter { $0.page == self } }
}

/// Every setting on a settings screen. The raw value is its stable name for tools and links.
public enum SettingID: String, CaseIterable, Sendable {
    // App
    case appAppearance = "app_appearance", appControlInk = "app_control_ink", appBackground = "app_background"
    case appLogin = "app_login", appLanguage = "app_language", appWindowSize = "app_window_size"
    // Bubble
    case bubbleHideAfter = "bubble_hide_after", bubbleLines = "bubble_lines", bubbleSize = "bubble_size"
    case bubbleAutoplay = "bubble_autoplay", bubbleAudio = "bubble_audio"
    case bubbleBackground = "bubble_background", bubbleAmount = "bubble_amount"
    // Talking
    case talkingListeningLanguage = "talking_listening_language", talkingTalkIn = "talking_talk_in"
    case talkingThreads = "talking_threads", talkingWindow = "talking_window", talkingWaiting = "talking_waiting"
    // Brains
    case brainsServices = "brains_services", brainsKeychain = "brains_keychain", brainsWait = "brains_wait"
    case brainsRetries = "brains_retries", brainsFirstWait = "brains_first_wait", brainsLonger = "brains_longer"
    // Devices
    case devicesHop = "devices_hop"
    case devicesLink = "devices_link", devicesPair = "devices_pair", devicesForgetAll = "devices_forget_all"
    // Sharing
    case sharingDen = "sharing_den"
    // Animations
    case animationsMade = "animations_made", animationsBuiltIn = "animations_built_in"
    // Privacy
    case privacyListening = "privacy_listening", privacyComputer = "privacy_computer"
    // Backup
    case backupExport = "backup_export", backupImport = "backup_import", backupReset = "backup_reset"
    // Per Imp: brain
    case brainSource = "brain_source"
    case brainSends = "brain_sends", brainTools = "brain_tools", brainNewChat = "brain_new_chat", brainCurrentChat = "brain_current_chat"
    // Per Imp: personality
    case personalityName = "personality_name", personalityPersona = "personality_persona", personalityAbout = "personality_about"
    case personalityVoice = "personality_voice", personalityVoiceLook = "personality_voice_look"
    case personalityRules = "personality_rules"
    // Per Imp: look
    case lookColour = "look_colour", lookSize = "look_size", lookCharacter = "look_character"
    // Per Imp: tools
    case toolsBuiltIn = "tools_built_in", toolsCommands = "tools_commands", toolsBrowser = "tools_browser", toolsExtra = "tools_extra"
    // Per Imp: triggers
    case triggersList = "triggers_list"
    // Per Imp: moves
    case movesFollowHow = "moves_follow_how", movesSpeed = "moves_speed", movesOwn = "moves_own", movesBuiltIn = "moves_builtin"

    /// Page, the key of the title on screen, and what the model is told. One row each.
    private struct Entry {
        let page: SettingsPlace, title: String, hint: String
    }

    private var entry: Entry {
        switch self {
        case .appAppearance: Entry(page: .app, title: "settings.app.appearance.title", hint: "light or dark mode, theme, colours of the app")
        case .appControlInk: Entry(page: .app, title: "settings.app.control_ink.title", hint: "white or black text, icons and switches on coloured buttons and controls")
        case .appBackground: Entry(page: .app, title: "menu.canvas.background", hint: "the desktop home's backdrop picture or colour")
        case .appLogin: Entry(page: .app, title: "app.login", hint: "start Imp when the Mac starts, launch at login")
        case .appLanguage: Entry(page: .app, title: "app.language", hint: "the language the app is shown in")
        case .appWindowSize: Entry(page: .app, title: "app.window.size", hint: "the size of the app's window, small, medium, large, full screen")
        case .bubbleHideAfter: Entry(page: .bubble, title: "settings.bubble.hide.title", hint: "how long a speech bubble stays before it hides")
        case .bubbleLines: Entry(page: .bubble, title: "settings.bubble.lines.title", hint: "how many lines of a reply the bubble shows")
        case .bubbleSize: Entry(page: .bubble, title: "settings.bubble.size.title", hint: "text size and width of the speech bubble")
        case .bubbleAutoplay: Entry(page: .bubble, title: "settings.bubble.autoplay.title", hint: "play videos and animated pictures in the bubble by themselves")
        case .bubbleAudio: Entry(page: .bubble, title: "settings.bubble.audio.title", hint: "when replies are read aloud, volume of speech, sound in the bubble")
        case .bubbleBackground: Entry(page: .bubble, title: "settings.bubble.background.title", hint: "a solid or see-through background for the speech bubble on the desktop")
        case .bubbleAmount: Entry(page: .bubble, title: "settings.bubble.amount.title", hint: "how see-through the speech bubble is")
        case .talkingListeningLanguage: Entry(page: .talking, title: "settings.talking.language.title", hint: "the language you speak to the Imp, dictation, microphone language")
        case .talkingTalkIn: Entry(page: .talking, title: "settings.talking.talk_in.title", hint: "where Imps talk to each other, in the bubble or in their own chat")
        case .talkingThreads: Entry(page: .talking, title: "settings.talking.threads.title", hint: "separate chats or one running conversation")
        case .talkingWaiting: Entry(page: .talking, title: "settings.talking.waiting.title", hint: "whether an Imp waits for another Imp's answer or goes on")
        case .talkingWindow: Entry(page: .talking, title: "settings.talking.window.title", hint: "how long before a chat starts over")
        case .brainsServices: Entry(page: .brains, title: "settings.group.brains", hint: "AI services the Imps can use, add an API, address, model, OpenAI, Claude, Ollama")
        case .brainsKeychain: Entry(page: .brains, title: "settings.brains.keychain.title", hint: "where API keys are stored, the Keychain")
        case .brainsWait: Entry(page: .brains, title: "settings.brains.wait.title", hint: "how long to wait for an AI answer, timeout")
        case .brainsRetries: Entry(page: .brains, title: "settings.brains.retries.title", hint: "how many times to try again when a request fails")
        case .brainsFirstWait: Entry(page: .brains, title: "settings.brains.first_wait.title", hint: "how long to wait for the first word of an answer")
        case .brainsLonger: Entry(page: .brains, title: "settings.brains.longer.title", hint: "wait longer for slow thinking models")
        case .devicesHop: Entry(page: .devices, title: "servers.hop.title", hint: "the Hop server that links devices, on this computer or elsewhere")
        case .devicesLink: Entry(page: .devices, title: "settings.devices.link.title", hint: "link the iPhone or another Mac, devices, pairing")
        case .devicesPair: Entry(page: .devices, title: "settings.devices.pair.title", hint: "pair a new device with a code or QR")
        case .devicesForgetAll: Entry(page: .devices, title: "settings.devices.forget_all.title", hint: "unlink every device")
        case .sharingDen: Entry(page: .sharing, title: "servers.den.title", hint: "the Den server where animations, triggers and Imps are shared and found")
        case .animationsMade: Entry(page: .animations, title: "animations.from_den", hint: "animations made or got from the Den, edit, rename, delete")
        case .animationsBuiltIn: Entry(page: .animations, title: "animations.built_in", hint: "the animations that come with Imp, restore, switch off")
        case .privacyListening: Entry(page: .privacy, title: "settings.privacy.core.title", hint: "microphone, speech recognition, what Imp may listen to")
        case .privacyComputer: Entry(page: .privacy, title: "settings.privacy.computer.title", hint: "permissions to see the screen, control the computer, accessibility, files")
        case .backupExport: Entry(page: .backup, title: "settings.backup.export.title", hint: "save a copy of all Imps and settings to a file")
        case .backupImport: Entry(page: .backup, title: "settings.backup.import.title", hint: "restore Imps and settings from a file")
        case .backupReset: Entry(page: .backup, title: "app.reset", hint: "erase everything and start over, factory reset")
        case .brainSource: Entry(page: .brain, title: "brain.source", hint: "use the shared Brain or its own one")
        case .brainSends: Entry(page: .brain, title: "memory.sends.title", hint: "how many of the latest messages go to the Brain with each one, memory, remembers")
        case .brainTools: Entry(page: .brain, title: "memory.tools.title", hint: "whether what the tools did and returned is sent back to the Brain, tool calls")
        case .brainNewChat: Entry(page: .brain, title: "memory.new_chat.title", hint: "the size at which a long chat gets a suggestion to recap or start a new chat")
        case .brainCurrentChat: Entry(page: .brain, title: "Current chat", hint: "let the Imp see the chat it is in")
        case .personalityName: Entry(page: .personality, title: "personality.name", hint: "the Imp's name and what it calls you")
        case .personalityAbout: Entry(page: .personality, title: "personality.about", hint: "what the Imp is good at, its description for the other Imps")
        case .personalityPersona: Entry(page: .personality, title: "personality.persona", hint: "who the Imp is, its character description and instructions")
        case .personalityVoice: Entry(page: .personality, title: "personality.voice", hint: "how the Imp sounds, the spoken voice")
        case .personalityVoiceLook: Entry(page: .personality, title: "personality.voice_look", hint: "how the Imp's voice looks while it speaks")
        case .personalityRules: Entry(page: .personality, title: "Reply rules", hint: "how long and in what style it answers")
        case .lookColour: Entry(page: .look, title: "look.colour", hint: "the Imp's colour or hue")
        case .lookSize: Entry(page: .look, title: "look.size", hint: "how big the Imp is")
        case .lookCharacter: Entry(page: .look, title: "look.character", hint: "the Imp's traits: horns, tail, eyes, ears and other features")
        case .toolsBuiltIn: Entry(page: .tools, title: "tools.built_in", hint: "which built-in abilities the Imp may use")
        case .toolsCommands: Entry(page: .tools, title: "Commands", hint: "let the Imp run commands on the Mac, shell, terminal")
        case .toolsBrowser: Entry(page: .tools, title: "Browser", hint: "let the Imp use the web browser, browser extension")
        case .toolsExtra: Entry(page: .tools, title: "tools.mcp", hint: "extra tools (MCP servers) and their keys or variables")
        case .triggersList: Entry(page: .triggers, title: "triggers.title", hint: "things the Imp does by itself when something happens or on a shortcut")
        case .movesFollowHow: Entry(page: .moves, title: "moves.follow_how", hint: "whether and how the Imp follows the mouse cursor")
        case .movesSpeed: Entry(page: .moves, title: "Speed", hint: "how fast the Imp moves")
        case .movesOwn: Entry(page: .moves, title: "Its own animations", hint: "animations made for just this Imp")
        case .movesBuiltIn: Entry(page: .moves, title: "moves.builtin", hint: "which built-in moves this Imp does")
        }
    }

    public var page: SettingsPlace { entry.page }
    /// The key of the text the setting shows on its screen.
    public var titleKey: String { entry.title }
    /// What the setting is and how a person may ask for it, for the model.
    public var hint: String { entry.hint }
    /// The setting belongs to an Imp, not to the whole app.
    public var isPerImp: Bool { page.isPerImp }

    /// The page and the setting a name from a tool or link means.
    public init?(name: String) { self.init(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) }
}

/// Where a request to open a setting lands, decided apart from any window.
public struct SettingsTarget: Equatable, Sendable {
    public var page: SettingsPlace
    public var setting: SettingID?
    /// The Imp named, when the page is an Imp's and another one than the asker was meant.
    public var imp: String?
    /// How long the setting stays lit before it fades.
    public static let highlightSeconds = 1.5

    public init(page: SettingsPlace, setting: SettingID? = nil, imp: String? = nil) {
        self.page = page; self.setting = setting; self.imp = imp
    }

    public init(setting: SettingID, imp: String? = nil) {
        self.init(page: setting.page, setting: setting, imp: setting.isPerImp ? imp : nil)
    }

    /// From the words of a tool call or a link: a setting, else a page. Nil when neither names something.
    public init?(setting: String?, page: String?, imp: String? = nil) {
        let named = imp.flatMap { $0.isEmpty ? nil : $0 }
        if let setting, let id = SettingID(name: setting) { self.init(setting: id, imp: named) }
        else if let page, let place = SettingsPlace(name: page) { self.init(page: place, imp: place.isPerImp ? named : nil) }
        else { return nil }
    }

    /// What is said back once it is open, in plain words.
    public var spoken: String {
        let pageName = page.rawValue
        let scope = page.isPerImp ? "the \(pageName) page of the Imp's settings" : "the \(pageName) page of the app's settings"
        guard let setting else { return "Opened \(scope). You cannot change settings yourself: tell the user what to set." }
        return "Opened \(scope) at \u{201C}\(setting.rawValue)\u{201D} (\(setting.hint)), highlighted. You cannot change settings yourself: tell the user what to set."
    }

    /// The reply when this device does not have the page.
    public var notOnThisDevice: String {
        "That setting is on the Mac, not on the iPhone. Tell the user where to find it: the \(page.rawValue) page."
    }
}

extension SettingsPlace {
    /// Every page with its settings in one compact text, for the tool's description. Built from the catalog.
    public static var overview: String {
        allCases.map { page in
            "\(page.isPerImp ? "Imp page" : "App page") \(page.rawValue): " + page.settings.map(\.rawValue).joined(separator: ", ")
        }.joined(separator: ". ")
    }
}
