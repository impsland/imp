import AppKit
import ImpKit
import Observation
import os

/// The app: preferences, the services every Imp shares (models and tools, the microphone,
/// global shortcuts, reactions) and the troupe itself. Each Imp is an `ImpModel`.
@MainActor @Observable
final class AppModel {
    var prefs: ImpPreferences { didSet { if prefs != oldValue { apply(prefs, previous: oldValue) } } }
    let assistant: Assistant
    /// The Imps out on the desktop (activated profiles, in their saved order). May be empty: then
    /// every Imp is waiting in the app's window.
    private(set) var imps: [ImpModel] = []
    /// The Imp you talked to last. Talk/Type from the menu bar and URL commands go to it.
    private(set) var focusID = ImpProfile.defaultID
    private(set) var failedHotkeys: Set<Hotkey> = []
    /// What Imps resting in the window are acting out (desktop Imps play theirs through `ImpLife`).
    private(set) var performances: [UUID: Performance] = [:]
    /// Every Imp out on the desktop is hidden (the menu bar's Hide). They're still out: the window
    /// shows them hiding under a sheet, and anything that calls on one brings them back.
    private(set) var isHidden = false

    @ObservationIgnored let dictation = Dictation()
    /// What Imp notices about the Mac: sets off triggers, and tells the model how the Mac is.
    @ObservationIgnored let senses = Senses()
    /// When each trigger last went off on its own (they rest a minute between goes).
    @ObservationIgnored private var lastFired: [UUID: Date] = [:]
    /// The last sustained processor load (busy triggers go off when it crosses their line).
    @ObservationIgnored private var lastLoad = 0
    /// Who has the microphone (one Imp at a time).
    @ObservationIgnored private weak var listener: ImpModel?
    @ObservationIgnored private(set) lazy var reactions = Reactions(app: self)
    @ObservationIgnored private(set) lazy var stage = Stage(app: self)
    /// Called after Imps appear or disappear, or hide or show. The panels follow.
    @ObservationIgnored var onTroupeChange: (() -> Void)?
    /// Flies an activated Imp's window to a screen point (back into the app's window), then calls back.
    @ObservationIgnored var flyHome: ((UUID, CGPoint, @escaping @MainActor () -> Void) -> Void)?
    @ObservationIgnored private var started = false

    /// Nil for offscreen design renders, which must never touch the user's saved preferences.
    @ObservationIgnored private let store: PreferencesStore?

    init(persist: Bool = true) {
        store = persist ? PreferencesStore() : nil
        assistant = Assistant(usesKeychain: persist)
        var loaded = store?.load() ?? ImpPreferences()
        loaded.upgrade()
        prefs = loaded
        store?.save(loaded)
        syncTroupe()
        dictation.onPartial = { [weak self] text in self?.listener?.updateListening(text) }
        dictation.onLevel = { [weak self] level in self?.listener?.micLevel = level }
        HotkeyCenter.shared.onPress = { [weak self] key in self?.handle(key) }
    }

    /// The Imp you talked to last (or the first one out), if any Imp is out on the desktop.
    var focused: ImpModel? { imps.first { $0.id == focusID } ?? imps.first }
    func imp(_ id: UUID) -> ImpModel? { imps.first { $0.id == id } }
    func focus(_ imp: ImpModel) { focusID = imp.id }
    func profile(_ id: UUID) -> ImpProfile? { prefs.imps.first { $0.id == id } }

    /// An Imp's models are set up well enough to chat (activated or not).
    func isReady(_ id: UUID) -> Bool { assistant.isReady(profile(id)?.brain) }

    /// The focused Imp (or, with none out, the first one) can talk to its models.
    var isReady: Bool { isReady(focused?.id ?? prefs.imps[0].id) }

    func start() {
        started = true
        Self.applyAppearance(prefs.appearance)
        assistant.configure(ai: prefs.ai, servers: prefs.liveServers, keychain: prefs.keysInKeychain)
        reactions.apply(prefs)
        HotkeyCenter.shared.install()
        registerHotkeys()
        imps.forEach { $0.start() }
        if let focused, !isReady { focused.greetNewcomer() }
        senses.onEvent = { [weak self] event in self?.fire(event) }
        senses.start()
        BrowserBridge.shared.onPage = { [weak self] page in self?.fire(.page(url: page.url, title: page.title)) }
        BrowserBridge.shared.start()
        // "Imp starts" once everyone's on screen.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.fire(.start)
        }
    }

    /// Something happened on the Mac: every trigger it sets off goes to its Imp, if that Imp is free
    /// (never in the middle of work, or while you're typing or talking to it). Each one rests a
    /// minute before it may go off again, and nothing goes off while the Imps are hidden.
    func fire(_ event: MacEvent) {
        defer { if case .busy(let load) = event { lastLoad = load } }
        guard !isHidden else { return }
        let state = senses.state
        for s in prefs.liveShortcuts where s.fires(on: event, in: state) {
            if case .busy = event, lastLoad >= s.trigger.percent { continue }     // still over the line: not news
            guard Date().timeIntervalSince(lastFired[s.id] ?? .distantPast) >= Self.rest,
                  let imp = performer(for: s), imp.isAvailable else { continue }
            lastFired[s.id] = Date()
            imp.perform(s, happened: event.description)
        }
    }

    /// Seconds a trigger rests after going off on its own.
    static let rest: TimeInterval = 60

    private func apply(_ p: ImpPreferences, previous old: ImpPreferences) {
        store?.save(p)
        if p.liveShortcuts.map(\.keys) != old.liveShortcuts.map(\.keys) { registerHotkeys() }
        if p.appearance != old.appearance { Self.applyAppearance(p.appearance) }
        if p.watchesCursor != old.watchesCursor { reactions.apply(p) }
        assistant.configure(ai: p.ai, servers: p.liveServers, keychain: p.keysInKeychain)
        if p.imps != old.imps {
            noticeFavoriteColors(p.imps, before: old.imps)
            syncTroupe()
            for imp in imps {
                let before = old.imps.first { $0.id == imp.id }
                if before?.scale != imp.profile.scale { imp.onScaleChange?() }
            }
        }
    }

    /// Light, dark or follow the system: applies to every window, bubble and menu.
    static func applyAppearance(_ a: Appearance) {
        NSApp.appearance = switch a {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func registerHotkeys() {
        failedHotkeys = HotkeyCenter.shared.register(prefs.liveShortcuts.compactMap(\.keys))
    }

    /// Hides every Imp on the desktop, or brings them back.
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        // Nobody can type into or talk to a hidden Imp: close its text box, stop listening.
        if hidden { imps.forEach { $0.stopWaitingForUser() } }
        onTroupeChange?()
    }

    // MARK: Animations

    /// Plays an animation on an Imp wherever it is: out on the desktop, or resting in the window.
    func perform(_ reaction: Reaction, on id: UUID) {
        if let imp = imp(id) {
            reactions.play(reaction, by: imp)
        } else {
            let performance = Performance(reaction)
            performances[id] = performance
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(performance.duration + 0.2))
                if self?.performances[id] == performance { self?.performances[id] = nil }
            }
        }
    }

    @ObservationIgnored private var favoriteAt: [UUID: Date] = [:]

    /// An Imp whose colour was just changed to its favourite lights up (and its swatch gets a heart).
    private func noticeFavoriteColors(_ imps: [ImpProfile], before: [ImpProfile]) {
        for imp in imps {
            guard let old = before.first(where: { $0.id == imp.id }), old.hue != imp.hue,
                  imp.isFavorite(imp.hue), !old.isFavorite(old.hue) else { continue }
            // Sliding back and forth over it shouldn't make a fuss every time.
            guard Date().timeIntervalSince(favoriteAt[imp.id] ?? .distantPast) > 2.5 else { continue }
            favoriteAt[imp.id] = Date()
            if !imp.knowsFavorite, let i = prefs.imps.firstIndex(where: { $0.id == imp.id }) { prefs.imps[i].knowsFavorite = true }
            if let reaction = prefs.animation(for: .favoriteColor) { perform(reaction, on: imp.id) }
        }
    }

    // MARK: Troupe

    /// Keeps one `ImpModel` per activated profile, reusing existing ones so nothing flickers.
    private func syncTroupe() {
        if prefs.imps.isEmpty {
            prefs.imps = [.waiting]
            return                                         // the didSet above re-enters with a valid troupe
        }
        let wanted = prefs.imps.filter(\.isActive).map(\.id)
        guard wanted != imps.map(\.id) else { return }
        let gone = imps.filter { !wanted.contains($0.id) }
        gone.forEach { $0.retire() }
        imps = wanted.map { id in imp(id) ?? ImpModel(id: id, app: self) }
        if imp(focusID) == nil, let first = imps.first { focusID = first.id }
        if started { imps.filter { im in !gone.contains { $0 === im } }.forEach { $0.startIfNeeded() } }
        onTroupeChange?()
    }

    /// Lets an Imp out onto the desktop (optionally exactly at `origin`, where it was drawn in the
    /// window, so it doesn't jump), or calls it back into the window.
    func setActive(_ id: UUID, _ on: Bool, at origin: CGPoint? = nil) {
        guard let i = prefs.imps.firstIndex(where: { $0.id == id }), prefs.imps[i].isActive != on else { return }
        if on { setHidden(false) }                         // letting one out means you want to see them
        var p = prefs
        if let origin { p.imps[i].origin = origin }
        p.imps[i].isActive = on
        prefs = p
        if on, let imp = imp(id) {
            focus(imp)
            if !imp.isReady { imp.greetNewcomer() }
        }
    }

    /// Hatches a new Imp: its own colour, name and personality, and a copy of `parent`'s models.
    /// It waits in the window until it's activated. Returns its id.
    @discardableResult
    func addImp(after parent: UUID? = nil) -> UUID {
        var profile = ImpProfile.newcomer(joining: prefs.imps)
        profile.name = ImpProfile.randomName(avoiding: prefs.imps.map(\.name))
        profile.personality = Persona.newcomer(named: profile.name)
        profile.isActive = false
        profile.brain = parent.flatMap { self.profile($0)?.brain }      // none: it follows the default brain
        prefs.imps.append(profile)
        return profile.id
    }

    /// Removes a service everywhere, its saved key included.
    func removeService(_ id: UUID) {
        prefs.removeService(id)
        assistant.setKey("", for: id)
    }

    /// Removes an Imp for good (never the last one), with its shortcuts.
    func removeImp(_ id: UUID) {
        guard prefs.imps.count > 1 else { return }
        var p = prefs
        p.imps.removeAll { $0.id == id }
        p.shortcuts.removeAll { $0.performer == id }
        prefs = p
        try? FileManager.default.removeItem(at: Workspace.directory(for: id))
        try? FileManager.default.removeItem(at: ChatHistory.folder(for: id))
    }

    /// Settings and history are read and written (false for offscreen design renders).
    var persists: Bool { store != nil }

    /// The Imp that performs an action: its own (if out), else the one you talked to last.
    func performer(for action: Shortcut) -> ImpModel? {
        imp(prefs.performer(of: action, fallback: focusID)) ?? focused
    }

    // MARK: Shortcuts and shortcuts

    /// A global shortcut: its Imp takes what's on the clipboard. (Only shortcuts of Imps that are
    /// out on the desktop listen. If two share keys, the first in the list wins.)
    func handle(_ hotkey: Hotkey) {
        // Pressing a shortcut while listening means "I'm done talking".
        if dictation.isRunning { dictation.finish(); return }
        guard let action = prefs.liveShortcuts.first(where: { $0.keys == hotkey }) else { return }
        trigger(action)
    }

    /// Runs a shortcut now (keys, menu, URL command, trying it in Settings), on the clipboard or on
    /// `text`. Trying a trigger that the Mac sets off says so to the model, so it plays along.
    func trigger(_ action: Shortcut, text: String? = nil, trying: Bool = false) {
        guard let imp = performer(for: action) else { return HomeWindow.shared.show(self) }
        setHidden(false)                                   // called on: out from under the sheet
        let happened = trying && action.trigger.kind.isAmbient
            ? "(A test run from Settings: imagine it just happened: \(action.triggerSummary).)" : nil
        imp.perform(action, clip: text.map(Clip.text), happened: happened)
    }

    func run(named name: String, text: String? = nil) {
        guard let action = prefs.shortcuts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            focused?.complain("I don't know a shortcut called “\(name)”.")
            return
        }
        trigger(action, text: text)
    }

    // Conveniences for the menu bar and URL commands: they go to the focused Imp. With every Imp
    // at home there's nobody to talk to, so the app's window opens instead.
    private func withFocused(_ work: (ImpModel) -> Void) {
        guard let focused else { return HomeWindow.shared.show(self) }
        setHidden(false)
        work(focused)
    }
    func talk() { withFocused { $0.talk() } }
    func startTyping(prefill: String = "") { withFocused { $0.startTyping(prefill: prefill) } }
    func submitTyped(_ text: String) { withFocused { $0.submitTyped(text) } }
    func ask(_ text: String, imp name: String? = nil) {
        let named = name.flatMap { n in imps.first { $0.profile.name.caseInsensitiveCompare(n) == .orderedSame } }
        if let named { setHidden(false); named.ask(text) } else { withFocused { $0.ask(text) } }
    }

    // MARK: Microphone (one listener at a time)

    func listen(for imp: ImpModel) async throws -> String {
        if let other = listener, other !== imp { other.cancel() }
        listener = imp
        defer { if listener === imp { listener = nil } }
        return try await dictation.listen(localeID: prefs.dictationLocale)
    }

    func stopListening(for imp: ImpModel) {
        if listener === imp, dictation.isRunning { dictation.cancel() }
    }

    func finishListening(for imp: ImpModel) -> Bool {
        guard listener === imp, dictation.isRunning else { return false }
        dictation.finish()
        return true
    }
}
