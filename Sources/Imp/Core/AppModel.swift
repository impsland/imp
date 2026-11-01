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
    /// Imps visiting the desktop from other devices: drawn here, thinking at their homes. They are
    /// not this Mac's Imps, so they have no place in its list or settings.
    private(set) var visitors: [ImpModel] = []
    /// The Imp you talked to last. Talk/Type from the menu bar and URL commands go to it.
    private(set) var focusID = ImpProfile.defaultID
    private(set) var failedHotkeys: Set<Hotkey> = []
    /// What Imps resting in the window are acting out (desktop Imps play theirs through `ImpLife`).
    private(set) var performances: [UUID: Performance] = [:]
    /// Every Imp out on the desktop is hidden (the menu bar's Hide). They're still out: the window
    /// shows them hiding under a sheet, and anything that calls on one brings them back.
    private(set) var isHidden = false
    /// Imps hidden one at a time (from an Imp's own menu), while the rest stay out. For this run of the app only, like `isHidden`.
    private(set) var hiddenImps: Set<UUID> = []

    /// Talks between Imps made up for offscreen design renders (added to what `talkLines()` finds).
    @ObservationIgnored var sampleTalks: [TalkLine] = []

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
    /// The devices Imps can be thrown to (see `docs/LINK.md`).
    @ObservationIgnored private(set) lazy var link = DeviceLink(app: self)
    /// Called after Imps appear or disappear, or hide or show. The panels follow.
    @ObservationIgnored var onTroupeChange: (() -> Void)?
    /// Flies an activated Imp's window to a screen point (back into the app's window), then calls back.
    @ObservationIgnored var flyHome: ((UUID, CGPoint, @escaping @MainActor () -> Void) -> Void)?
    /// Throws an Imp's window off the desktop towards a device, then calls back.
    @ObservationIgnored var flyOff: ((UUID, UUID, @escaping @MainActor () -> Void) -> Void)?
    /// An Imp back from another device, or a visitor, flies in from a side of the desktop.
    @ObservationIgnored var flyIn: ((UUID, LinkEntry) -> Void)?
    /// A visitor that leaves for good flies off past a side of the desktop, then calls back.
    @ObservationIgnored var flyAway: ((UUID, LinkSide, @escaping @MainActor () -> Void) -> Void)?
    /// The visitors on their way out (their panels are still flying off).
    @ObservationIgnored private var leaving: Set<UUID> = []
    @ObservationIgnored private var started = false
    /// Everything was just wiped (see `resetToFirstLaunch`): never save again in this run.
    @ObservationIgnored private var erased = false
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "app")

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

    /// The Imp you talked to last (or the first one out), if any Imp is out on the desktop. Imps on
    /// an iPhone are out too, but you talk to them on the phone.
    var focused: ImpModel? {
        let here = imps.filter { !isAway($0.id) }
        return here.first { $0.id == focusID } ?? here.first
    }
    func imp(_ id: UUID) -> ImpModel? { imps.first { $0.id == id } }
    func visitor(_ id: UUID) -> ImpModel? { visitors.first { $0.id == id } }
    /// Every Imp body on the desktop: this Mac's own, and the visitors.
    var bodies: [ImpModel] { imps + visitors }
    func body(_ id: UUID) -> ImpModel? { imp(id) ?? visitor(id) }
    func focus(_ imp: ImpModel) { focusID = imp.id }
    func profile(_ id: UUID) -> ImpProfile? { prefs.imps.first { $0.id == id } }

    /// An Imp's models are set up well enough to chat (activated or not).
    func isReady(_ id: UUID) -> Bool { assistant.isReady(profile(id)?.brain) }

    /// The focused Imp (or, with none out, the first one) can talk to its models.
    var isReady: Bool { isReady(focused?.id ?? prefs.imps[0].id) }

    func start() {
        started = true
        // Ask the user's shell for its PATH now, so the first tool server or command doesn't wait.
        Task.detached(priority: .utility) { _ = await LoginEnvironment.resolved() }
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
        tellBrowser()
        link.start()
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
                  let imp = performer(for: s), imp.isAvailable, !hiddenImps.contains(imp.id), !isAway(imp.id) else { continue }
            lastFired[s.id] = Date()
            imp.perform(s, happened: event.description)
        }
    }

    /// Seconds a trigger rests after going off on its own.
    static let rest: TimeInterval = 60

    private func apply(_ p: ImpPreferences, previous old: ImpPreferences) {
        if !erased { store?.save(p) }
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

    /// Hides every Imp on the desktop, or brings them back (bringing them back shows the ones
    /// hidden one at a time too).
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden || (!hidden && !hiddenImps.isEmpty) else { return }
        isHidden = hidden
        if !hidden { hiddenImps = [] }
        // Nobody can type into or talk to a hidden Imp: close its text box, stop listening.
        if hidden { bodies.forEach { $0.stopWaitingForUser() } }
        onTroupeChange?()
    }

    /// Hides one Imp (the others stay out), or brings it back.
    func setHidden(_ id: UUID, _ hidden: Bool) {
        if hidden {
            guard !hiddenImps.contains(id) else { return }
            hiddenImps.insert(id)
            body(id)?.stopWaitingForUser()
        } else {
            guard isHidden || hiddenImps.contains(id) else { return }
            hiddenImps.remove(id)
            if isHidden {
                // Everyone was hidden: just this one comes back.
                isHidden = false
                hiddenImps.formUnion(bodies.map(\.id).filter { $0 != id })
            }
        }
        onTroupeChange?()
    }

    /// Whether this Imp is out of sight (all hidden, or it alone).
    func isHiding(_ id: UUID) -> Bool { isHidden || hiddenImps.contains(id) }

    /// Some Imp that's out is hidden (the menu bar then offers Show).
    var anyHiding: Bool { !imps.isEmpty && (isHidden || bodies.contains { hiddenImps.contains($0.id) }) }

    // MARK: Animations

    /// Plays an animation on an Imp wherever it is: out on the desktop, or resting in the window.
    func perform(_ reaction: Reaction, on id: UUID) { perform(.preset(reaction), on: id) }

    func perform(_ ref: AnimationRef, on id: UUID) {
        if let imp = imp(id) {
            reactions.play(ref, by: imp)
        } else {
            let performance = Performance(ref, prefs: prefs, imp: id)
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
            if let ref = prefs.ref(for: .favoriteColor, imp: imp.id) { perform(ref, on: imp.id) }
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
    /// window, so it doesn't jump), or calls it back into the window (from an iPhone too).
    func setActive(_ id: UUID, _ on: Bool, at origin: CGPoint? = nil) {
        guard let i = prefs.imps.firstIndex(where: { $0.id == id }), prefs.imps[i].isActive != on else { return }
        if on { setHidden(false) }                         // letting one out means you want to see them
        hiddenImps.remove(id)
        var p = prefs
        if let origin { p.imps[i].origin = origin }
        p.imps[i].isActive = on
        if !on, p.imps[i].awayOn != nil || isThrowing(id) {
            p.imps[i].awayOn = nil
            link.callHome(id)
        }
        prefs = p
        if on, let imp = imp(id) {
            focus(imp)
            if !imp.isReady { imp.greetNewcomer() }
        }
    }

    // MARK: Other devices

    /// Whether this Imp is on another device (out, but not on the desktop).
    func isAway(_ id: UUID) -> Bool { profile(id)?.awayOn != nil }

    /// Imps out on the desktop itself (not on another device): the ones that see each other.
    var desktopImps: [ImpModel] { imps.filter { !isAway($0.id) } }

    /// What a throw off the desktop needs to remember until the other device answers.
    private struct Throw {
        var imp: UUID
        var side: LinkSide
        var height: Double
    }

    /// Throws that wait for an answer, by transfer. The Imp's window is on its way off the desktop,
    /// but its body stays here until the other device takes it.
    @ObservationIgnored private var throwing: [UUID: Throw] = [:]

    /// Throws an Imp off `side` of the desktop towards `device`: it lands there coming in from the
    /// other side. False when it can't go (the device isn't around any more). Its window is on its way
    /// off the desktop; the answer decides whether it stays away (`passed`) or comes back.
    @discardableResult
    func send(_ id: UUID, to device: UUID, side: LinkSide, height: Double, speed: Double) -> Bool {
        guard let look = thrownLook(id), !throwing.values.contains(where: { $0.imp == id }),
              let transfer = link.pass(look, entry: .after(exit: side, height: height, speed: speed), to: device) else { return false }
        throwing[transfer] = Throw(imp: id, side: side, height: height)
        body(id)?.stopWaitingForUser()                     // a text box can't follow it
        hiddenImps.remove(id)
        return true
    }

    /// How an Imp on the desktop is thrown on: one of this Mac's that is out here, or a visitor.
    private func thrownLook(_ id: UUID) -> LinkImp? {
        if let profile = profile(id) { return profile.isActive && profile.awayOn == nil ? LinkImp(profile) : nil }
        return visitor(id)?.visit?.look
    }

    /// From the menu: off the nearer side of the screen, gently, onto a device.
    func send(_ id: UUID, to device: UUID) {
        guard link.isConnected(device), !isAway(id) else { return }
        let fly = flyOff ?? { _, _, done in done() }
        fly(id, device) { [weak self] in self?.refreshTroupe() }
    }

    /// A thrown Imp was taken (it stays away, held by that device) or sent back (it flies in again
    /// and says why).
    func passed(_ passed: LinkNode.Passed) {
        guard passed.kind == .pass else { return }
        guard let thrown = throwing.removeValue(forKey: passed.transfer) else {
            // A visitor we passed on whose `took` came after we gave up: the other device has it, so this body goes.
            if passed.outcome == .took, let late = visitor(passed.imp), !link.isVisiting(passed.imp) {
                late.retire()
                visitors.removeAll { $0 === late }
                refreshTroupe()
            }
            return
        }
        switch passed.outcome {
        case .took:
            if let visitor = visitor(thrown.imp) {
                visitor.retire()                           // on to another device: this body is done
                visitors.removeAll { $0 === visitor }
            } else if let profile = profile(thrown.imp), profile.isActive, link.holder(of: thrown.imp) == passed.to {
                held(thrown.imp, by: passed.to)
            } else {
                // Deleted, called in or taken back while it was on its way: the other device lets go.
                link.callHome(thrown.imp)
                if let profile = profile(thrown.imp), profile.isActive, profile.awayOn == nil {
                    arrive(thrown.imp, entry: LinkEntry(side: thrown.side, height: thrown.height, speed: 900))
                }
            }
            refreshTroupe()
        case .declined(let reason):
            // Deleted or called in meanwhile: nothing to bring back.
            guard visitor(thrown.imp) != nil || profile(thrown.imp)?.isActive == true else { return }
            let text = DeviceLink.hint(reason, device: link.name(of: passed.to) ?? String(localized: "That device"))
            arrive(thrown.imp, entry: LinkEntry(side: thrown.side, height: thrown.height, speed: 900))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.3))
                self?.body(thrown.imp)?.complain(text)
            }
        }
    }

    /// A device holds this Imp now: it is out, but not on the desktop.
    func held(_ id: UUID, by device: UUID) {
        guard let i = prefs.imps.firstIndex(where: { $0.id == id }), prefs.imps[i].awayOn != device else { return }
        prefs.imps[i].awayOn = device
        hiddenImps.remove(id)
        link.watch(id)
    }

    /// At start, the link's ledger says where each Imp is: that is the truth, whatever was saved.
    func reconcileAway(_ holders: [UUID: UUID]) {
        var p = prefs
        for i in p.imps.indices { p.imps[i].awayOn = holders[p.imps[i].id] }
        if p != prefs { prefs = p }
    }

    /// Back from another device (thrown off it, or called back here): it flies onto the desktop
    /// through `entry`, else through the side nearest its spot.
    func cameHome(_ id: UUID, entry: LinkEntry? = nil) {
        guard let i = prefs.imps.firstIndex(where: { $0.id == id }) else { return }
        guard prefs.imps[i].awayOn != nil else {
            // Still on its way to a device that is gone: it flies back in.
            if let flight = throwing.first(where: { $0.value.imp == id }) {
                throwing[flight.key] = nil
                arrive(id, entry: entry ?? LinkEntry(side: flight.value.side, height: flight.value.height, speed: 900))
            }
            return
        }
        prefs.imps[i].awayOn = nil
        link.forget(imp: id)
        let screen = NSScreen.main?.frame ?? .zero
        let x = prefs.imps[i].origin?.x ?? screen.maxX
        arrive(id, entry: entry ?? LinkEntry(side: x < screen.midX ? .left : .right, height: 0.6, speed: 0))
    }

    /// An Imp comes onto the desktop through a side of the screen.
    private func arrive(_ id: UUID, entry: LinkEntry) {
        if isHidden { setHidden(id, false) }
        flyIn?(id, entry)
        refreshTroupe()
        if let imp = imp(id) { focus(imp) }
    }

    /// A pocket Imp that moves in for good (the user agreed in the kit review): a new Mac Imp with
    /// the id it had, its chats, its service (found by address or added, and its key saved only if
    /// that service has none) and its tool servers. It flies in from the side opposite the one it
    /// left by. Throws why it can't.
    func adoptPocket(_ id: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry) throws {
        var p = prefs
        let adoption = try p.adopt(kit: kit, as: id, secrets: secrets)
        guard let i = p.imps.firstIndex(where: { $0.id == id }) else { return }
        p.imps[i].isActive = true
        // Chats go to the Imp's folder before it appears, so it opens them as its own.
        if persists {
            var history = ChatHistory(folder: ChatHistory.folder(for: id))
            for chat in adoption.imp.chats { history.adopt(chat) }
        }
        prefs = p
        if let service = adoption.service, let key = adoption.apiKey, !assistant.hasKey(service) {
            assistant.setKey(key, for: service)
        }
        arrive(id, entry: entry)
    }

    /// Calls an Imp back from the device that holds it, in through the side of the screen nearest its spot.
    func callBack(_ id: UUID) {
        link.callHome(id)
        cameHome(id)
    }

    /// Whether an Imp of this Mac is on its way to another device (thrown, not yet answered).
    func isThrowing(_ id: UUID) -> Bool { throwing.values.contains { $0.imp == id } }

    /// The panels follow who's where.
    func refreshTroupe() { onTroupeChange?() }

    // MARK: Visiting Imps

    /// A visiting Imp is here: it flies in through `entry`, or (no entry: it was visiting before
    /// the app started) waits at its seat. One already here only has its looks and home updated.
    func welcome(_ visiting: Visiting, entry: LinkEntry?) {
        let id = visiting.look.id
        leaving.remove(id)
        if let model = visitor(id) {
            model.update(visiting)
        } else {
            let model = ImpModel(id: id, app: self, visiting: visiting)
            visitors.append(model)
            if started { model.start() }
        }
        guard let entry else { return refreshTroupe() }
        if isHiding(id) { setHidden(id, false) }
        flyIn?(id, entry)
        refreshTroupe()
    }

    /// A visitor leaves for good (its home called it back, or it was sent home): it flies off past
    /// the side it came in by, and is gone.
    func farewell(visitor id: UUID) {
        guard let model = visitor(id), leaving.insert(id).inserted else { return }
        let side = model.visit?.side ?? .left
        model.retire()
        let gone: @MainActor () -> Void = { [weak self] in
            guard let self, leaving.remove(id) != nil else { return }
            visitors.removeAll { $0.id == id }
            refreshTroupe()
        }
        guard let flyAway else { return gone() }
        flyAway(id, side, gone)
    }

    /// Sends a visiting Imp home from here: its body leaves now, and its home hears when it can.
    func sendHome(visitor id: UUID) {
        guard visitor(id) != nil, link.sendHome(visitor: id) else { return }
        farewell(visitor: id)
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

    /// Keeps the browser extension's popup told which Imps are out, how they look and how they
    /// are (thinking, asleep…), as it changes. Nothing they said goes there.
    private func tellBrowser() {
        let troupe = withObservationTracking {
            imps.map { imp in
                let p = imp.profile
                return BridgeImp(name: p.name, hue: p.hue, scale: p.scale, traits: p.traits, mood: (imp.activity?.mood ?? .idle).rawValue, away: p.awayOn != nil)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.tellBrowser() }
        }
        BrowserBridge.shared.setTroupe(troupe)
    }

    /// Removes a service everywhere, its saved key included.
    func removeService(_ id: UUID) {
        prefs.removeService(id)
        assistant.setKey("", for: id)
    }

    /// Removes an Imp for good (never the last one), with its shortcuts.
    func removeImp(_ id: UUID) {
        guard prefs.imps.count > 1 else { return }
        if isAway(id) || isThrowing(id) { link.callHome(id) }
        var p = prefs
        p.imps.removeAll { $0.id == id }
        p.shortcuts.removeAll { $0.performer == id }
        prefs = p
        try? FileManager.default.removeItem(at: Workspace.directory(for: id))
        ChatHistory.deleteFolder(for: id)
        if persists { DenAccounts(inKeychain: prefs.keysInKeychain).forget(imp: id) }
    }

    /// Calls an Imp in and removes it for good (never the last one). Returns the Imp that took
    /// its place in the line, to show next.
    @discardableResult
    func sayGoodbye(_ id: UUID) -> UUID? {
        guard prefs.imps.count > 1, let i = prefs.imps.firstIndex(where: { $0.id == id }) else { return nil }
        setActive(id, false)
        removeImp(id)
        let ids = prefs.imps.map(\.id)
        return ids[min(i, ids.count - 1)]
    }

    /// Back to the very first launch: every Imp, service, key, borrowed tool, trigger, chat and
    /// setting goes, Imp stops opening at login and forgets its macOS permissions, then quits and
    /// opens again fresh. Nothing is saved after this (the wipe must not be undone on the way out).
    func resetToFirstLaunch() {
        guard persists else { return }
        erased = true
        if dictation.isRunning { dictation.cancel() }
        if LoginItem.isEnabled { try? LoginItem.set(false) }
        let left = FactoryReset.app().erase()
        if !left.isEmpty { log.error("Reset left behind: \(left.joined(separator: ", "), privacy: .public)") }
        Self.relaunchAfterExit(resettingPermissions: Bundle.main.bundleIdentifier)
        exit(0)                              // not terminate: nothing may write settings back on the way out
    }

    /// Quits and opens again (a new language applies from launch). Settings are saved on the way out.
    func relaunch() {
        Self.relaunchAfterExit(resettingPermissions: nil)
        NSApp.terminate(nil)
    }

    /// Opens this app again once this process has gone. macOS permissions (microphone, speech,
    /// automation) can only be forgotten from outside, so the same helper resets them first.
    private static func relaunchAfterExit(resettingPermissions bundleID: String?) {
        let reset = bundleID.map { id in
            ["Microphone", "SpeechRecognition", "AppleEvents"].map { "/usr/bin/tccutil reset \($0) '\(id)' >/dev/null 2>&1;" }.joined(separator: " ")
        } ?? ""
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; \(reset) /usr/bin/open \"$2\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "imp-relaunch", String(getpid()), Bundle.main.bundlePath]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
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
        setHidden(imp.id, false)                           // called on: out from under the sheet
        let happened = trying && action.trigger.kind.isAmbient
            ? "(A test run from Settings: imagine it just happened: \(action.triggerSummary).)" : nil
        imp.perform(action, clip: text.map(Clip.text), happened: happened)
    }

    func run(named name: String, text: String? = nil) {
        guard let action = prefs.shortcuts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            focused?.complain(String(localized: "I don't know a trigger called “\(name)”."))
            return
        }
        trigger(action, text: text)
    }

    // Conveniences for the menu bar and URL commands: they go to the focused Imp. With every Imp
    // at home there's nobody to talk to, so the app's window opens instead.
    private func withFocused(_ work: (ImpModel) -> Void) {
        guard let focused else { return HomeWindow.shared.show(self) }
        setHidden(focused.id, false)
        work(focused)
    }
    func talk() { withFocused { $0.talk() } }
    func startTyping(prefill: String = "") { withFocused { $0.startTyping(prefill: prefill) } }
    func submitTyped(_ text: String) { withFocused { $0.submitTyped(text) } }
    func ask(_ text: String, imp name: String? = nil) {
        let named = name.flatMap { n in imps.first { $0.profile.name.caseInsensitiveCompare(n) == .orderedSame } }
        if let named { setHidden(named.id, false); named.ask(text) } else { withFocused { $0.ask(text) } }
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
