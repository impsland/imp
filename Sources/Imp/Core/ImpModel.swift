import AppKit
import ImpKit
import Observation
import os

/// One Imp of the troupe: its mood, bubble, conversation memory and request pipeline.
/// Who it is (name, colour, personality, model) lives in its `ImpProfile`. Shared services
/// (models, tools, the microphone) come from the `AppModel`.
@MainActor @Observable
final class ImpModel {
    let id: UUID
    @ObservationIgnored unowned let app: AppModel
    let life = ImpLife()
    /// Its own rhythm for breath, blinks and wiggles, so a troupe doesn't move in lockstep.
    let clock: BodyClock

    /// What it's saying or asking. The bubble and `activity` move together: a text box or a
    /// listening bubble is the Imp waiting for you, so whenever it goes away (closed, timed out,
    /// replaced) the waiting ends too, and stopping a job takes its work-in-progress bubble with it.
    private(set) var bubble: Bubble? {
        didSet {
            if let waiting = activity?.waitingPhase, bubble?.phase != waiting { endWaiting() }
            // A bubble that went away can't report the pointer leaving it: the next starts fresh.
            if bubble?.id != oldValue?.id { bubbleHovered = false }
            onBubbleChange?()
        }
    }
    /// What this Imp is busy with while a job runs.
    private(set) var activity: Activity?
    /// When the current activity began (for glyph pop-ins).
    private(set) var activitySince = Date()
    /// A short-lived reaction (happy, sad, surprised…).
    private(set) var flash: (mood: Mood, until: Date)?
    var micLevel = 0.0
    private(set) var lastActivity = Date()
    /// This Imp's panel on screen (for following the cursor, mouse games and the stage).
    var impFrame: CGRect = .zero
    /// Degrees it swings while you carry it around (it lags behind the way it's going).
    var carryLean = 0.0

    /// Where the cursor is while this Imp should be going after it (nil: it stays put). Set by its
    /// inner life a few times a second, read by its window while it hops or glides.
    @ObservationIgnored var followCursor: CGPoint?
    /// Starts the window following `followCursor` (it does nothing when already there).
    @ObservationIgnored var onFollow: (() -> Void)?
    /// You have hold of it, or just did: it doesn't run after the cursor until then.
    @ObservationIgnored var followBlockedUntil = Date.distantPast

    @ObservationIgnored var onBubbleChange: (() -> Void)?
    @ObservationIgnored var onScaleChange: (() -> Void)?
    /// Moves its window to a screen point (the bottom-left of its panel), the way `Travel` says.
    @ObservationIgnored var onTravel: ((CGPoint, Travel) async -> Void)?
    /// Where it lives when it isn't off somewhere (`imp_move` to "home").
    @ObservationIgnored var homeOrigin: (() -> CGPoint)?
    /// Animations the model asked for (`imp_play_animations`, maybe over several calls), in order:
    /// they wait for its reply to show, then join `acting`.
    @ObservationIgnored private var pendingActs: [AnimationRef] = []
    /// Animations playing one after another (the first is on now). New ones join the end.
    @ObservationIgnored private var acting: [AnimationRef] = []
    @ObservationIgnored private var actTask: Task<Void, Never>?
    /// Animations one answer may line up, all calls together (a long show is no longer body language).
    static let maxActs = 8
    /// Another Imp waiting for this one's answer (`imp_message`).
    @ObservationIgnored private var replyTo: CheckedContinuation<String, Error>?
    /// Its window can be seen (not covered, on another Space, or on a sleeping display). When it
    /// can't, nothing is drawn.
    var isOnScreen = true
    /// The view switched between resting (breath done by Core Animation) and drawing every frame.
    @ObservationIgnored var onRestingChange: ((Bool) -> Void)?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// The current bubble may time out (finished answers, hints and errors, unless shown to stay).
    @ObservationIgnored private var bubbleMayHide = false
    /// The pointer is on the bubble: it waits for you (the clock starts again when you leave).
    @ObservationIgnored private var bubbleHovered = false
    /// The bubble the user made theirs (read in full, moved or resized): it stays until closed.
    @ObservationIgnored private var keptBubble: UUID?
    @ObservationIgnored private var playbackObserver: NSObjectProtocol?
    /// Its chats, kept across launches: the one you're in (what the chat shows, and what the
    /// model remembers of it) and the saved ones to go back to.
    private(set) var history: ChatHistory
    /// Set for an Imp visiting from another device: its body is here and its brain at its home, so
    /// what it says and does comes from there (see "Visiting" at the end of this file).
    private(set) var visit: Visiting?
    /// Turns answered while the chat was open: only their media may start on its own
    /// (`#autoplay`); older turns never replay when you scroll back to them.
    private(set) var freshTurns: Set<UUID> = []
    /// The model is writing a recap of the current chat.
    private(set) var isRecapping = false
    /// Why the last recap didn't work (nil once one does).
    private(set) var recapError: String?
    @ObservationIgnored private var recapTask: Task<Void, Never>?
    /// The bubble the history replaced, to go back to.
    @ObservationIgnored private var beforeChat: Bubble?

    /// The request being worked on: what was asked, its steps and the answer so far. Kept apart
    /// from the bubble, so the work carries on (and shows in the history) whatever the bubble shows.
    struct Work: Equatable {
        /// The request in full (words, a shortcut's instruction, what was copied, a picture),
        /// as the history shows and keeps it.
        var ask: ChatTurn
        /// The thinking bubble's heading, and the answer's title.
        var heading: String
        var title: String
        var steps: [Bubble.Step] = []
        /// The answer as it streams in (empty while thinking or using tools).
        var text = ""
        /// Another Imp's question this work answers (its bubble says who asked).
        var received: Bubble.Exchange?
        /// A question this Imp put to another Imp, while it waits for the answer.
        var asking: Bubble.Exchange?
        /// The Imp whose chat of its own this work belongs to (nil: the chat you're in).
        var peerChat: ChatTurn.Sender?
        /// Goes on in the latest chat with that Imp (false: a new conversation).
        var continuing = true
    }
    private(set) var work: Work?
    /// The work, if it belongs in the chat you're in: talk with another Imp in a chat of its own
    /// doesn't show in (or touch) another chat.
    var chatWork: Work? {
        guard let w = work else { return nil }
        guard let peer = w.peerChat else { return w }
        return history.current.peer == peer.id ? w : nil
    }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var streamShownAt = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "imp")

    /// Asleep: a trigger put it to sleep (by default, being left alone for a while) and nothing has
    /// woken it since. Touching it, or a wake-up trigger, does.
    private(set) var asleep = false

    init(id: UUID, app: AppModel, visiting: Visiting? = nil) {
        self.id = id
        self.app = app
        visit = visiting
        clock = BodyClock(id)
        // A visitor's chats are its home's: what it shows is a copy of the current one.
        history = app.persists && visiting == nil ? ChatHistory(folder: ChatHistory.folder(for: id))
                                                  : ChatHistory(folder: nil)
        // Audio or video in the bubble holds it up while it plays; the clock starts when it stops.
        playbackObserver = NotificationCenter.default.addObserver(forName: Playback.didChange, object: nil,
                                                                  queue: .main) { [weak self] note in
            let owner = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let owner, owner == self.bubble?.id.uuidString else { return }
                self.scheduleHide()
            }
        }
    }

    var profile: ImpProfile { visit?.profile ?? app.prefs.imps.first { $0.id == id } ?? .imp }
    var prefs: ImpPreferences { app.prefs }
    /// The model this Imp uses: its own, or the default.
    var isReady: Bool { app.assistant.isReady(profile.brain) }
    var impCenter: CGPoint { CGPoint(x: impFrame.midX, y: impFrame.midY) }
    /// Where the head itself is on screen, from the character's design proportions.
    var headOnScreen: (center: CGPoint, radius: CGFloat) {
        let side = impFrame.width, base = ImpRenderer.size
        let equator = (base.bottom - base.base) / 100
        return (CGPoint(x: impFrame.midX, y: impFrame.maxY - side * equator), side * base.rx / 100)
    }

    func start() {
        started = true
        life.start(self)
    }

    func startIfNeeded() { if !started { start() } }

    /// It went home (or left the troupe): stop everything, including its inner life's timer, and
    /// put its bubble away.
    func retire() {
        cancel()
        stopActing()
        hideTask?.cancel()
        life.stop()
        started = false
        bubble = nil
    }

    func greetNewcomer() {
        show(Bubble(title: String(localized: "Hi, I'm \(profile.name)"),
                    text: String(localized: "Give me a brain (any OpenAI-compatible AI service) and we can chat. I can work your Mac too: ask me to open an app or fetch something."),
                    phase: .hint, link: .settings), autoHide: false)
        react(.happy, for: 2)
    }

    // MARK: Mood

    /// Whether it can think: at home, its own brain decides; a visitor's home tells (`Wakefulness`).
    var wakefulness: Wakefulness { visit?.wakefulness ?? .atHome(brainReady: isReady) }

    func mood(at date: Date) -> Mood {
        // It can't think (no usable brain, or its home is away): asleep, whatever it is doing, as on
        // the iPhone. Asking it says why (`refuseAsleep`).
        if !wakefulness.isAwake { return .sleepy }
        if let flash, flash.until > date { return flash.mood }
        if let activity { return activity.mood }
        if let m = life.step?.mood { return m }
        if asleep { return .sleepy }
        return .idle
    }

    var isBusy: Bool { activity != nil }

    private func setActivity(_ a: Activity?) {
        guard a != activity else { return }
        activity = a
        activitySince = Date()
    }

    /// Nothing going on: no job, no bubble, no reaction, not asleep.
    func isFree(at date: Date) -> Bool {
        (flash.map { $0.until <= date } ?? true) && !isBusy && bubble == nil && !asleep && wakefulness.isAwake
    }

    /// 0…1 "energy" for the current mood (mic loudness).
    var level: Double { activity == .listening ? micLevel : 0 }

    func react(_ mood: Mood, for seconds: Double) {
        if life.antic?.isWake == false { life.cancel() }
        flash = (mood, Date().addingTimeInterval(seconds))
        if app.isAway(id) { app.link.animate(id, beats: [AnimationBeat(duration: seconds, mood: mood.rawValue)]) }
    }

    func touch() {
        lastActivity = Date()
        asleep = false
        if life.antic?.isWake == false { life.cancel() }
    }

    // MARK: Bubble

    private func show(_ b: Bubble, autoHide: Bool = true) {
        bubbleMayHide = autoHide
        bubble = b
        scheduleHide()
    }

    /// Only a finished bubble times out: never a text box, a listening or thinking bubble, or an
    /// answer still streaming in (hovering over and off those must not start the clock). Nor
    /// while you're with it: the pointer is on it, its audio or video plays, or you made it yours.
    private var bubbleCanTimeOut: Bool {
        guard bubbleMayHide, let b = bubble, !b.isStreaming, activity == nil else { return false }
        return BubbleTimeout.mayHide(finished: [.result, .error, .hint].contains(b.phase),
                                     hovered: bubbleHovered, kept: keptBubble == b.id,
                                     playing: Playback.shared.isPlaying(owner: b.id.uuidString))
    }

    /// (Re)starts the auto-hide clock, if this bubble has one.
    func scheduleHide() {
        hideTask?.cancel()
        let seconds = prefs.bubbleAutoHideSeconds
        guard seconds > 0, bubbleCanTimeOut, let shown = bubble?.id else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.bubble?.id == shown, self.bubbleCanTimeOut else { return }
            self.bubble = nil
        }
    }

    /// The pointer came onto the bubble (the clock stops) or left it (it starts over, in full).
    func bubbleHover(_ inside: Bool) {
        bubbleHovered = inside
        scheduleHide()
    }

    /// The user opened the bubble in full, moved or resized it: it's theirs, it stays till closed.
    func keepBubble() {
        guard let id = bubble?.id, keptBubble != id else { return }
        keptBubble = id
        scheduleHide()
    }

    /// Closes a text box or listening bubble, if it's showing (work in progress carries on).
    func stopWaitingForUser() {
        if activity?.waitingPhase != nil { dismissBubble() }
    }

    func dismissBubble() {
        cancel()
        bubble = nil
    }

    // MARK: Chat

    /// Whether the bubble is the chat: everything said so far, with a text box to keep talking.
    /// Work started from it streams into it instead of into a speech bubble.
    var isChatting: Bool { bubble?.phase == .chat }

    /// Opens the chat in the bubble (the bubble showing now comes back after).
    func openChat() {
        guard bubble?.phase != .chat else { return }
        touch()
        beforeChat = bubble
        show(Bubble(phase: .chat), autoHide: false)
    }

    /// Back from the chat: to the work in progress, else the text box or answer it replaced
    /// (or the answer that arrived meanwhile), else nothing.
    func closeChat() {
        let before = beforeChat
        beforeChat = nil
        if let work {
            show(work.text.isEmpty
                 ? Bubble(title: work.heading, text: Captions.thinking.randomElement()!, phase: .thinking, steps: work.steps)
                 : Bubble(title: work.title, text: work.text, phase: .result, steps: work.steps, isStreaming: true),
                 autoHide: false)
            return
        }
        switch before?.phase {
        case .typing?: startTyping()
        case .result?, .error?, .hint?: show(before!)
        default: bubble = nil
        }
    }

    // MARK: Saved chats

    /// Starts a fresh chat; the one you were in stays in the list to come back to.
    func newChat() {
        if visit?.isAwake == false { return }              // its home keeps the chats, and it can't hear
        stopForChatChange()
        history.startNew()
        if visit != nil { app.link.newChat(id) }
    }

    /// New Chat from the chat panel: the panel closes and a fresh text box opens above the Imp
    /// (the chat it left stays in the list).
    func startNewChat() {
        newChat()
        beforeChat = nil
        startTyping()
    }

    /// Carries on in a saved chat, where it left off (the model remembers it as it was).
    func switchChat(to chat: UUID) {
        guard chat != history.current.id else { return }
        stopForChatChange()
        history.open(chat)
    }

    /// A chat from a file: listed first, ready to carry on in (the chat you're in stays as it is).
    func importChat(_ chat: Chat) { history.adopt(chat) }

    /// Deletes a chat for good: what was said, and the model's memory of it.
    func deleteChat(_ chat: UUID) {
        if chat == history.current.id { stopForChatChange() }
        history.delete(chat)
    }

    /// Shows `sample` as its chats (offscreen design renders only).
    func showSample(_ sample: ChatHistory) { history = sample }

    /// Work in progress belongs to the chat it started in: stop it before changing chats.
    private func stopForChatChange() {
        if work != nil { cancel() }
        recapTask?.cancel()
        recapError = nil
    }

    /// Something to recap: more than the last exchange is remembered.
    var canRecap: Bool { visit == nil && history.current.memory.exchangeCount > 1 && work == nil && !isRecapping }

    /// Has the model sum up the current chat, then forgets everything before the last exchange
    /// in favour of that recap (it shows in the chat; the turns above it stay there to read).
    /// For a chat that's grown too long for the model, or costly to send.
    func recapChat() {
        guard canRecap else { return }
        let chat = history.current.id
        let request = Recap.request(history.current.memory, name: profile.name)
        let covered = history.current.memory.exchangeCount
        isRecapping = true
        recapError = nil
        recapTask = Task { [weak self, brain = profile.brain] in
            guard let self else { return }
            defer { self.isRecapping = false }
            do {
                let (summary, _) = try await self.app.assistant.chat(request, brain: brain, tools: nil)
                try Task.checkCancellation()
                guard self.history.current.id == chat else { return }
                self.history.recap(summary, covering: covered)
                self.log.info("\(self.profile.name, privacy: .public) recapped a chat")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.recapError = error.localizedDescription
                self.log.error("recap failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Adds the finished (or failed) request to the chat, with what the model should remember
    /// of it (`exchange`: nil when it never got an answer).
    private func record(_ ask: ChatTurn?, reply: String, failed: Bool = false, exchange: [ChatMessage]? = nil,
                        peerChat: ChatTurn.Sender? = nil, continuing: Bool = true) {
        guard var turn = ask else { return }
        turn.reply = reply
        turn.failed = failed
        turn.steps = finishedSteps.compactMap(\.saved)
        if let peerChat {
            history.append(turn, remembering: exchange, withPeer: peerChat, continuing: continuing)
            return
        }
        if isChatting && !failed { freshTurns.insert(turn.id) }
        history.append(turn, remembering: exchange)
        if visit == nil, !failed {
            history.checkContext(threshold: app.prefs.contextNoticeTokens, exchanges: profile.memoryExchanges, tools: profile.remembersToolCalls)
        }
    }

    /// The long-chat suggestion is up for the chat you're in.
    var showsContextNotice: Bool { visit == nil && history.contextNoticeShown }

    /// Waves the long-chat suggestion away (it never comes back for this chat).
    func dismissContextNotice() { history.dismissContextNotice() }

    func perform(_ link: Bubble.Link) {
        switch link {
        case .settings: HomeWindow.shared.show(app, settingsFor: id, tab: isReady ? nil : .brain)
        }
    }

    func copyBubble() {
        guard let b = bubble else { return }
        Pasteboard.write(text: b.text)
        react(.love, for: 1.2)
    }

    // MARK: Intents

    /// Stops everything in flight. A bubble that only made sense while it ran (thinking, a
    /// half-streamed answer, listening, an open text box) goes with it. Finished ones stay.
    func cancel() {
        job?.cancel()
        job = nil
        // Stopped half-way (✕, a click, a new request): the history still shows what it did.
        if let w = work {
            // A visitor's home keeps the chat: it is told to stop, and records it.
            if visit == nil { record(w.ask, reply: String(localized: "Stopped before answering."), failed: true, peerChat: w.peerChat, continuing: w.continuing) }
            else { app.link.stop(id) }
        }
        work = nil
        pendingActs = []
        finishReply(.failure(ToolArgumentError("\(profile.name) stopped before answering.")))
        captionTask?.cancel()
        app.stopListening(for: self)
        setActivity(nil)
        micLevel = 0
        if let b = bubble, b.isStreaming || [.thinking, .listening, .typing].contains(b.phase) { bubble = nil }
    }

    /// The text box or listening bubble went away: stop waiting for the user.
    private func endWaiting() {
        if activity == .listening { app.stopListening(for: self) }
        micLevel = 0
        setActivity(nil)
    }

    /// Clicks on this Imp (`count` in a row): stops whatever it's doing, else does what that many
    /// clicks are set to (Triggers tab: out of the box, one types and two open settings).
    func clicked(_ count: Int) {
        if visit != nil { return clickedVisitor() }
        touch()
        app.focus(self)
        if app.finishListening(for: self) { return }
        if [.thinking, .tools].contains(activity) { cancel(); react(.surprised, for: 0.6); return }
        guard let shortcut = prefs.clickShortcut(count, on: id, in: app.senses.state) else { return }
        perform(shortcut)
    }

    /// Whether clicks wait to see if more follow (only when something answers to more than one).
    var waitsForMoreClicks: Bool { prefs.mostClicks(on: id) > 1 }

    /// Talk to this Imp (voice), or stop talking.
    func talk() {
        touch()
        app.focus(self)
        if app.finishListening(for: self) { return }
        if [.thinking, .tools].contains(activity) { cancel(); react(.surprised, for: 0.6); return }
        start(.spoken)
    }

    /// Opens a text box in the bubble: type to this Imp instead of talking.
    func startTyping(prefill: String = "", prompt: String? = nil) {
        guard wakefulness.isAwake else { return refuseAsleep() }
        touch()
        if visit == nil { app.focus(self) }
        cancel()
        setActivity(.typing)
        show(Bubble(text: prefill, phase: .typing, prompt: prompt ?? String(localized: "Ask \(profile.name) anything…")), autoHide: false)
    }

    /// Sends the text box (the bubble's, or the chat's): the words, and the picture pasted into
    /// it, if any.
    func submitTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let picture = takesTyping ? bubble?.attachment : nil
        guard !t.isEmpty || picture != nil else { return }
        if isChatting, var b = bubble, b.attachment != nil {
            b.attachment = nil                          // sent: the chat's box is empty again
            bubble = b
        }
        start(.typed(t, picture))
    }

    /// What's typed in the bubble's text box so far: the bubble grows with it, line by line, so
    /// every line stays in sight (up to the field's own limit, after which it scrolls).
    func typingChanged(_ text: String) {
        guard var b = bubble, b.phase == .typing, b.text != text else { return }
        b.text = text
        bubble = b
    }

    /// The bubble has a text box: the typing bubble, or the chat.
    private var takesTyping: Bool { bubble?.phase == .typing || isChatting }

    /// Something pasted into the text box (⌘V or ⌃V): a picture rides along with the message.
    /// Returns false when there's no text box to take it.
    @discardableResult
    func attach(_ picture: EncodedImage) -> Bool {
        guard var b = bubble, takesTyping, visit == nil else { return false }
        b.attachment = picture
        bubble = b
        return true
    }

    /// A picture dragged over this Imp: it perks up (and settles when the drag moves away).
    func pictureHover(_ over: Bool) {
        touch()
        if over { react(.surprised, for: 1.5) } else { flash = nil }
    }

    /// A picture dropped on this Imp: it rides along with your next message. The chat's text box
    /// takes it if the chat is open, else a text box opens above the Imp (keeping what you typed).
    func receive(_ picture: EncodedImage) {
        app.focus(self)
        if !takesTyping { startTyping() }
        attach(picture)
        react(.happy, for: 1.0)
    }

    func removeAttachment() {
        guard var b = bubble, takesTyping, b.attachment != nil else { return }
        b.attachment = nil
        bubble = b
    }

    /// A trigger went off: opens what it opens, or hands its instruction to the model, with what's
    /// on the clipboard (or `clip`, from a URL command) unless it sends the instruction alone.
    /// `happened`: what set it off on the Mac (nil: the user did, with keys, clicks or a menu).
    func perform(_ shortcut: Shortcut, clip given: Clip? = nil, happened: String? = nil) {
        if shortcut.runsLocally { return runLocal(shortcut) }
        touch()
        app.focus(self)
        switch shortcut.command {
        case .type: return bubble?.phase == .typing ? dismissBubble() : startTyping()
        case .talk: return talk()
        case .chat: return isChatting ? closeChat() : openChat()
        case .settings:
            stopWaitingForUser()
            return HomeWindow.shared.show(app, settingsFor: id, tab: isReady ? nil : .brain)
        case .sleep, .wakeUp, .play: return
        case .ask: break
        }
        if let given { return start(.shortcut(shortcut, given, happened: happened)) }
        guard shortcut.usesClipboard else { return start(.shortcut(shortcut, nil, happened: happened)) }
        guard let clip = Pasteboard.clip() else {
            // Something on the Mac set it off: go ahead without a clip rather than complain.
            return happened == nil ? nothingCopied(shortcut) : start(.shortcut(shortcut, nil, happened: happened))
        }
        start(.shortcut(shortcut, clip, happened: happened))
    }

    /// A trigger that acts on the body alone: no brain, no model call, just the Imp.
    func runLocal(_ shortcut: Shortcut) {
        switch shortcut.command {
        case .sleep: fallAsleep(playing: shortcut.animation)
        case .wakeUp: wakeUp(playing: shortcut.animation)
        case .play: if let ref = shortcut.animation { life.perform(ref) }
        default: break
        }
    }

    /// Falls asleep, playing `ref` on the way if there is one.
    func fallAsleep(playing ref: AnimationRef?) {
        guard !asleep, wakefulness.isAwake else { return }
        asleep = true
        if let ref { life.perform(ref) }
    }

    /// Wakes up with `ref`, or its built-in wake-up. Does nothing for an Imp that is awake, or one
    /// that can't think (no usable brain, or its home is away): it sleeps until that changes.
    func wakeUp(playing ref: AnimationRef?) {
        guard wakefulness.isAwake, asleep else { return }
        touch()
        if let ref { life.perform(ref) } else { life.wake() }
    }

    /// Free to take on something the Mac set off: not working, and you're not typing, talking or chatting to it.
    var isAvailable: Bool {
        !isBusy && ![.typing, .listening, .chat].contains(bubble?.phase)
    }

    /// Another Imp's message (`imp_message`): this Imp answers in its own bubble, and the answer
    /// goes back. Never interrupts work in progress.
    /// `limitedTo` names the device it comes from when that isn't one of the owner's own: the Imp
    /// answers without any tool then.
    func answer(_ text: String, from sender: ChatTurn.Sender, in place: ImpTalk.Place, conversation: String? = nil,
                limitedTo device: String? = nil) async throws -> String {
        guard !isBusy else { throw ToolArgumentError("\(profile.name) is busy right now. Try again later.") }
        // Files either side mentions are named by their owner Imp, so the other one can open them
        // (a path relative to one Workspace means nothing in another). See `WorkspaceReference`.
        let said = WorkspaceReference.canonicalize(text, owner: sender.id)
        let reply: String = try await withCheckedThrowingContinuation { c in
            start(.message(from: sender, text: said, place: place, conversation: conversation), limitedTo: device)
            replyTo = c
        }
        return WorkspaceReference.canonicalize(reply, owner: profile.id)
    }

    private func finishReply(_ result: Result<String, Error>) {
        guard let waiting = replyTo else { return }
        replyTo = nil
        waiting.resume(with: result)
    }

    /// Plays animations the model asked for, after any it asked for before (every call counts,
    /// none replaces another): now if it's free, else once its reply shows. Returns how many
    /// fitted (see `maxActs`).
    @discardableResult
    func act(_ reactions: [AnimationRef]) -> Int {
        let room = max(Self.maxActs - pendingActs.count - acting.count, 0)
        let taken = Array(reactions.prefix(room))
        if isBusy { pendingActs += taken } else { play(taken) }
        return taken.count
    }

    /// Lines `reactions` up behind whatever is playing; each starts when the one before is done.
    private func play(_ reactions: [AnimationRef]) {
        acting += reactions
        guard actTask == nil, !acting.isEmpty else { return }
        actTask = Task { [weak self] in
            while !Task.isCancelled, let self, let r = self.acting.first {
                self.app.reactions.play(r, by: self)
                try? await Task.sleep(for: .seconds(self.life.steps(for: r).reduce(0) { $0 + $1.duration } + 0.15))
                if !self.acting.isEmpty { self.acting.removeFirst() }
            }
            self?.actTask = nil
        }
    }

    /// Drops the animations lined up and the one playing (a new request, going home).
    private func stopActing() {
        pendingActs = []
        acting = []
        actTask?.cancel()
        actTask = nil
    }

    /// A question from another app (URL command).
    /// `limitedTo` names the device it comes from when that isn't one of the owner's own: the Imp
    /// answers without any tool then.
    func ask(_ text: String, limitedTo device: String? = nil) {
        start(.typed(text, nil), limitedTo: device)
    }

    /// Something went wrong outside a request (an unknown shortcut name from a URL command).
    func complain(_ text: String) {
        react(.error, for: 1.5)
        show(Bubble(title: String(localized: "Hmm"), text: text, phase: .error))
    }

    /// Four quick clicks: whatever animation answers to pokes (a tantrum, out of the box).
    func flurry() {
        touch()
        felt(.poke)
        // The first click opened a text box. A poking spree isn't a conversation.
        stopWaitingForUser()
        guard let ref = prefs.ref(for: .poke, imp: id) else { return }
        cancel()
        app.reactions.play(ref, by: self)
        guard ref == .preset(.angry), visit == nil else { return }
        let lines = [String(localized: "Poke me again and I'll translate your diary into Klingon."),
                     String(localized: "I bite. Metaphorically. Mostly."),
                     String(localized: "I'm a demon, not a stress ball."),
                     String(localized: "Careful. My horns are still growing.")]
        show(Bubble(title: String(localized: "Ow"), text: lines.randomElement()!, phase: .hint))
    }

    // MARK: Pipeline

    /// Where a request comes from. Every one goes the same way: the Imp's model gets the words
    /// (and any picture) with its tools, and decides what to do.
    enum Source {
        /// Typed into the bubble (with a pasted picture, maybe), or sent by another app.
        case typed(String, EncodedImage?)
        /// Said out loud: listen first.
        case spoken
        /// A trigger's instruction, with what was copied (nil: the instruction alone) and what set
        /// it off on the Mac (nil: the user did).
        case shortcut(Shortcut, Clip?, happened: String?)
        /// Another Imp's message (`imp_message`).
        case message(from: ChatTurn.Sender, text: String, place: ImpTalk.Place, conversation: String?)
    }

    private func start(_ source: Source, limitedTo device: String? = nil) {
        if visit != nil { return askHome(source) }
        // Asked by you while it can't think: refused at once, with what to do. (Another Imp's
        // message and a trigger still run, and fail with the same sentence in their own way.)
        switch source {
        case .typed, .spoken: guard wakefulness.isAwake else { return refuseAsleep() }
        case .shortcut, .message: break
        }
        touch()
        app.focus(self)
        cancel()
        stopActing()                                  // the last answer's show is over
        recapTask?.cancel()                           // a new turn would slip past the recap
        showPending(source)
        job = Task { await run(source, limitedTo: device) }
    }

    /// Typed words show at once, before the job has started: in the chat as the newest turn with
    /// its dots (the earlier turns stay), else as the thinking bubble (the text box doesn't blink
    /// away while the job starts). `run` takes over with the real request.
    private func showPending(_ source: Source) {
        guard case .typed(let words, _) = source else { return }
        let heading = words.isEmpty ? String(localized: "A picture") : "“\(words)”"
        work = Work(ask: ChatTurn(request: words, via: .typed), heading: heading, title: "")
        thinking(heading, captions: Captions.thinking)
    }

    private func nothingCopied(_ shortcut: Shortcut) {
        react(.sad, for: 1.8)
        let text = shortcut.hotkey.map { String(localized: "Your clipboard is empty. Copy some text or a picture first, then press \($0.displayString) again.") }
            ?? String(localized: "Your clipboard is empty. Copy some text or a picture first.")
        show(Bubble(title: shortcut.name, text: text, phase: .hint))
    }

    private func run(_ source: Source, limitedTo device: String? = nil) async {
        var title = ""
        /// What you asked, for the history (nil until there's something to answer).
        var ask: ChatTurn?
        var received: Bubble.Exchange?, peerChat: ChatTurn.Sender?, continuing = true
        do {
            let turn: ChatMessage, heading: String
            switch source {
            case .typed(let words, let picture):
                let path = picture.flatMap(save)
                turn = Briefing.message(words, image: picture, imagePath: path)
                heading = words.isEmpty ? String(localized: "A picture") : "“\(words)”"
                ask = ChatTurn(request: words, via: .typed, picture: path)
            case .spoken:
                let words = try await listen()
                turn = Briefing.message(words)
                heading = "“\(words)”"
                ask = ChatTurn(request: words, via: .spoken)
            case .shortcut(let shortcut, let clip, let happened):
                title = shortcut.name
                var path: String?
                if case .image(let picture)? = clip { path = save(picture) }
                turn = happened.map { Briefing.trigger(shortcut.prompt, name: shortcut.name, happened: $0, clip: clip, imagePath: path) }
                    ?? Briefing.shortcut(shortcut.prompt, clip: clip, imagePath: path)
                heading = shortcut.name
                let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                var copied: String?
                if case .text(let text)? = clip { copied = text }
                ask = ChatTurn(request: shortcut.name, via: .shortcut, instruction: instruction.isEmpty ? nil : instruction,
                               copiedText: copied, picture: path)
            case .message(let sender, let text, let place, let conversation):
                turn = Briefing.message(from: sender.name, text)
                heading = "“\(text)”"
                ask = ChatTurn(request: text, via: .imp, sender: sender)
                received = Bubble.Exchange(role: .asked, peer: sender, question: text)
                if place == .own {
                    peerChat = sender
                    continuing = app.prefs.talkThreading.continues(asked: conversation, last: history.lastTalk(withPeer: sender.id),
                                                                   windowMinutes: app.prefs.talkWindowMinutes)
                }
            }
            work = ask.map { Work(ask: $0, heading: heading, title: title, received: received, peerChat: peerChat, continuing: continuing) }
            log.info("\(self.profile.name, privacy: .public) works on “\(title.isEmpty ? "a message" : title, privacy: .public)”")
            // No usable brain (a transferred Imp, say): say so and what to do, at once.
            if let problem = app.assistant.problem(with: profile.brain, imp: profile.name) { throw problem }
            thinking(heading, captions: Captions.thinking)
            var messaging = true
            if case .message = source { messaging = false }       // answering an Imp: no messaging back and forth
            // Asked from a device that isn't the owner's own: plain conversation, nothing that acts.
            let tools = device != nil ? nil
                : try app.assistant.tools(for: profile, own: ImpTools(host: OwnToolHost(app: app, imp: id, messaging: messaging)))
            if device == nil, app.assistant.toolsConnecting { addStep(.wakingUp) }
            let (reply, exchange) = try await app.assistant.chat(messages(with: turn, peer: peerChat, continuing: continuing, limitedTo: device), brain: profile.brain, tools: tools,
                                                                 stream: true) { [weak self] event in
                self?.progress(event, title: title)
            }
            try Task.checkCancellation()
            record(ask, reply: reply, exchange: exchange, peerChat: peerChat, continuing: continuing)
            showAnswer(reply, title: title)
            finishReply(.success(reply))
        } catch is CancellationError {
            dropWork()
            finishReply(.failure(ToolArgumentError("\(profile.name) stopped before answering.")))
        } catch let error as Dictation.Failure where error == .heardNothing {
            // Offer the keyboard instead of a dead end.
            react(.sad, for: 1.2)
            startTyping(prompt: String(localized: "I didn't catch that. Type it?"))
        } catch {
            guard !Task.isCancelled else { return }
            record(ask, reply: error.localizedDescription, failed: true, peerChat: peerChat, continuing: continuing)
            fail(title.isEmpty ? String(localized: "thinking") : title, error)
            finishReply(.failure(ToolArgumentError("\(profile.name) couldn't answer: \(error.localizedDescription)")))
        }
    }

    /// Listens until you stop talking. The words you said.
    private func listen() async throws -> String {
        setActivity(.listening)
        show(Bubble(text: "", phase: .listening), autoHide: false)
        defer { micLevel = 0 }
        // Starting the audio engine blocks the main thread briefly: let the bubble appear first.
        try await Task.sleep(for: .milliseconds(60))
        let text = try await app.listen(for: self)
        setActivity(nil)
        return text
    }

    /// Its personality and instructions, the chat so far (as much as it's set to be sent), then
    /// the new turn. Its workspace is made first: the instructions send files there.
    private func messages(with turn: ChatMessage, peer: ChatTurn.Sender? = nil, continuing: Bool = true, limitedTo device: String? = nil) -> [ChatMessage] {
        let p = profile
        try? FileManager.default.createDirectory(at: p.workspace, withIntermediateDirectories: true)
        let memory = peer.map { continuing ? history.memory(withPeer: $0.id) : ChatMemory() } ?? history.current.memory
        let note = device.map { Self.limitNote(for: $0) } ?? ""
        return memory.context(system: p.systemPrompt + note, turn: turn,
                                              exchanges: p.memoryExchanges, tools: p.remembersToolCalls)
    }

    /// Said to the model when it has no tools because of who asks, so it doesn't pretend otherwise.
    static func limitNote(for device: String) -> String {
        "\n\nThis request comes from \(device), which is not one of your owner's own devices, so you have no tools for it: "
            + "no commands, no control of the computer, nothing that acts. Just talk. If it asks you to do something that needs "
            + "them, say plainly: \"I can't use my tools for \(device).\""
    }

    /// A picture you handed over, saved in its workspace so its commands can use it. The path.
    private func save(_ picture: EncodedImage) -> String? {
        do { return try Workspace.save(picture, in: Workspace.directory(for: id)).path }
        catch {
            log.error("couldn't save a picture: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A job stopped half-way: nothing in progress may linger (the mood, the caption ticker, a
    /// thinking or half-streamed bubble).
    private func dropWork() {
        setActivity(nil)
        captionTask?.cancel()
        if let b = bubble, b.isStreaming || b.phase == .thinking { bubble = nil }
    }

    private func fail(_ what: String, _ error: Error) {
        setActivity(nil)
        captionTask?.cancel()
        log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        pendingActs = []
        react(.error, for: 2.2)
        app.stage.broadcast(.failed, from: self)
        // Setup problems point at the Brain tab and stay until dealt with.
        let needsSetup = switch error as? APIError {
        case .missingKey?, .keyDenied?, .noService?, .noModel?, .needsBrain?: true
        default: false
        }
        work = nil
        let failure = Bubble(title: String(localized: "Oops: \(what)"), text: error.localizedDescription, phase: .error,
                             link: needsSetup ? .settings : nil)
        // In the chat: it shows there, and comes up when you go back.
        if bubble?.phase == .chat { beforeChat = failure } else { show(failure, autoHide: !needsSetup) }
    }

    /// The finished answer: the bubble the stream was filling (same bubble, now with its buttons),
    /// and a happy bounce.
    private func showAnswer(_ text: String, title: String) {
        setActivity(nil)
        captionTask?.cancel()
        // Body language the model chose takes the place of the usual happy bounce.
        if pendingActs.isEmpty { react(.happy, for: 1.0) } else { play(pendingActs); pendingActs = [] }
        app.stage.broadcast(.answered, from: self)
        let streaming = bubble?.isStreaming == true ? bubble : nil
        // The turn's id when it has none yet: media the chat already autoplayed won't play again here.
        var answer = Bubble(id: streaming?.id ?? work?.ask.id ?? UUID(), title: title, text: text, phase: .result, steps: finishedSteps)
        answer.exchange = work?.received?.asReply
        work = nil
        // In the chat: the answer shows there, and comes up when you go back.
        if bubble?.phase == .chat { beforeChat = answer } else { show(answer) }
    }

    // MARK: Streaming

    /// The answer so far, as it streams in. The first words end the thinking. After that the bubble updates at most ~20 times a second (each update re-measures it).
    private func stream(_ text: String, title: String) {
        guard !text.isEmpty else { return }
        let first = work?.text.isEmpty ?? (bubble?.isStreaming != true)
        guard first || Date().timeIntervalSince(streamShownAt) >= 0.05 else { return }
        streamShownAt = Date()
        work?.text = text
        if first {
            setActivity(nil)
            captionTask?.cancel()
        }
        guard !isChatting else { return }                    // it streams into the chat instead
        var b = bubble ?? Bubble(phase: .result)
        b.title = title
        b.text = text
        b.phase = .result
        b.isStreaming = true
        b.exchange = work?.received?.asReply
        hideTask?.cancel()
        bubble = b
    }

    /// The model wrote a little, then turned to a tool after all: back to "working".
    private func stopStreaming() {
        work?.text = ""                                // superseded by the tool calls
        guard var b = bubble, b.isStreaming else { return }
        b.isStreaming = false
        b.phase = .thinking
        b.text = Captions.thinking.randomElement()!
        b.exchange = work?.asking ?? work?.received
        bubble = b
    }

    func updateListening(_ text: String) {
        guard var b = bubble, b.phase == .listening else { return }
        b.text = text
        bubble = b
    }

    // MARK: Thinking (a little humour while we wait)

    private func thinking(_ title: String, captions: [String]) {
        setActivity(.thinking)
        // In the chat, the work shows as the newest turn: no thinking bubble, no captions.
        guard !isChatting else { captionTask?.cancel(); return }
        var shuffled = captions.shuffled()
        var b = Bubble(title: title, text: shuffled[0], phase: .thinking)
        b.exchange = work?.received
        show(b, autoHide: false)
        captionTask?.cancel()
        captionTask = Task { [weak self] in
            var i = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                guard !Task.isCancelled else { return }
                if i % shuffled.count == 0 { shuffled.shuffle() }
                self?.caption(shuffled[i % shuffled.count])
                i += 1
            }
        }
    }

    // MARK: Steps (commands and tools)

    private func addStep(_ step: Bubble.Step) {
        guard var w = work else { return }
        // Anything still "waking up" is done once real work starts.
        for i in w.steps.indices where w.steps[i].tool == nil { w.steps[i].state = .done }
        w.steps.append(step)
        work = w
        showSteps()
    }

    /// A thinking bubble shows the work's steps (the history reads them from `work` itself).
    private func showSteps() {
        guard var b = bubble, b.phase == .thinking, let work else { return }
        b.steps = work.steps
        b.exchange = work.asking ?? work.received
        bubble = b
    }

    private func progress(_ event: AgentEvent, title: String) {
        switch event {
        case .text(let text):
            endRetryNote()
            stream(text, title: title)
        case .retrying(let notice):
            showRetry(notice)
        case .toolStarted(let name, let arguments):
            stopStreaming()
            setActivity(.tools)
            let label = ToolLabel(tool: name, arguments: arguments)
            if name == OwnTools.message { askAnother(arguments) }
            addStep(Bubble.Step(icon: label.icon, title: label.title, tool: name, request: label.request))
        case .toolFinished(let name, let ok, let result):
            guard var w = work, let i = w.steps.lastIndex(where: { $0.tool == name && $0.state == .running }) else { return }
            w.steps[i].state = ok ? .done : .failed
            w.steps[i].response = Bubble.Step.clipped(result)
            if name == OwnTools.message { w.asking = nil }
            work = w
            showSteps()
            setActivity(.thinking)                     // back to the model with the result
        }
    }

    /// "Retrying 2 of 3": the network hiccuped and the request goes again. One step, kept up to date.
    private func showRetry(_ notice: RetryNotice) {
        guard var w = work else { return }
        let step = Bubble.Step(icon: "arrow.clockwise", title: notice.text)
        if let i = w.steps.lastIndex(where: { $0.tool == nil && $0.icon == step.icon }) {
            w.steps[i].title = step.title
            w.steps[i].state = .running
        } else {
            w.steps.append(step)
        }
        work = w
        showSteps()
    }

    /// The retry went through (or the answer started): its note is done.
    private func endRetryNote() {
        guard var w = work, let i = w.steps.lastIndex(where: { $0.tool == nil && $0.icon == "arrow.clockwise" && $0.state == .running }) else { return }
        w.steps[i].state = .done
        work = w
    }

    /// Steps of the finished job, with anything still running marked done.
    private var finishedSteps: [Bubble.Step] {
        (work?.steps ?? []).map { var s = $0; if s.state == .running { s.state = .done }; return s }
    }

    /// This Imp put a question to another Imp (`imp_message`): its bubble says whom it waits for.
    private func askAnother(_ arguments: String) {
        guard work != nil, let args = try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments),
              let to = args["to"]?.string, let text = args["text"]?.string,
              let other = app.imps.first(where: { $0.profile.name.caseInsensitiveCompare(to) == .orderedSame })?.profile else { return }
        work?.asking = Bubble.Exchange(role: .asking, peer: ChatTurn.Sender(id: other.id, name: other.name, hue: other.hue), question: text)
    }

    private func caption(_ text: String) {
        guard var b = bubble, b.phase == .thinking else { return }
        b.text = text
        bubble = b
    }
}

// MARK: Visiting
//
// An Imp visiting from another device has no brain here. It asks its home, and shows what the home
// says it is doing (`heard`): the work as it streams in, the chat, its mood, the talks it has with
// other Imps and the animations it plays.

extension ImpModel {
    /// Its looks changed, or its home came or went. A home that goes out of reach puts it to sleep,
    /// and what it was working on can't go on.
    func update(_ visiting: Visiting) {
        let before = visit
        guard visiting != before else { return }
        visit = visiting
        if before?.look.scale != visiting.look.scale { onScaleChange?() }
        guard before?.isAwake != false, !visiting.isAwake else { return }
        work = nil
        dropWork()
        if bubble?.exchange != nil { bubble = nil }
    }

    /// The chat at its home, as the home shows it.
    func heard(chat turns: [LinkTurn]) {
        var copy = ChatHistory(folder: nil)
        for t in turns {
            let steps = t.steps.map { ChatTurn.Step(icon: "wrench.and.screwdriver", title: $0, request: "", response: nil, failed: false) }
            copy.append(ChatTurn(id: t.id, date: t.date, request: t.request, reply: t.reply, failed: t.failed, steps: steps, via: .typed))
        }
        history = copy
    }

    /// What it is working on at its home: the request, the step it is at and the answer so far. When
    /// the work ends, the answer (or what went wrong) is the newest turn of the chat.
    func heard(work heard: LinkWork?) {
        guard let heard else {
            guard work != nil else { return }
            if let last = history.turns.last, last.failed { fail(String(localized: "thinking"), ToolArgumentError(last.reply)) }
            else { showAnswer(history.turns.last?.reply ?? "", title: "") }
            return
        }
        // Answering another Imp shows as a talk bubble (`heard(speech:)`), not as work.
        guard heard.from == nil else { return }
        if work == nil {
            let heading = "“\(heard.request)”"
            work = Work(ask: ChatTurn(request: heard.request, via: .typed), heading: heading, title: "")
            thinking(heading, captions: Captions.thinking)
        }
        if let status = heard.status, var current = work, current.steps.last?.title != status {
            // Read, change, then write back in one step: `work?.steps = work?.steps…` begins
            // changing `work` before it reads it, and Swift stops the app on that overlap.
            current.steps = current.steps.map { var s = $0; s.state = .done; return s }
            work = current
            addStep(Bubble.Step(icon: "gearshape", title: status, tool: "home"))
        }
        stream(heard.partial, title: "")
    }

    /// What it is feeling at its home: thinking and using tools show as they do on any Imp.
    func heard(mood name: String) {
        switch Mood(rawValue: name) {
        case .working?: setActivity(.tools)
        case .thinking?: setActivity(.thinking)
        default: if work == nil { setActivity(nil) }
        }
    }

    /// What it says to another Imp, or another Imp to it, as a bubble over its head. The home hides
    /// the bubble when its time is up (an answer also leaves on this Mac's own clock).
    func heard(speech: LinkSpeech?) {
        guard let speech else {
            if let b = bubble, b.exchange != nil, b.phase == .thinking { bubble = nil }
            return
        }
        // Not over a text box, the chat or its own work.
        guard bubble == nil || bubble?.exchange != nil else { return }
        let role: Bubble.Exchange.Role = switch speech.role {
        case .asked: .asked
        case .reply: .reply
        case .asking: .asking
        }
        let peer = ChatTurn.Sender(id: speech.id, name: speech.peer, hue: speech.hue)
        let exchange = Bubble.Exchange(role: role, peer: peer, question: speech.question)
        if speech.role == .reply {
            var b = Bubble(id: speech.id, text: speech.text, phase: .result)
            b.exchange = exchange
            show(b)
        } else if bubble?.id != speech.id {
            var b = Bubble(id: speech.id, title: "“\(speech.question)”", text: Captions.thinking.randomElement()!, phase: .thinking)
            b.exchange = exchange
            show(b, autoHide: false)
        }
    }

    /// The home acts an animation out on this body.
    func acted(_ beats: [AnimationBeat]) {
        guard visit?.isAwake == true else { return }
        touch()
        life.perform(beats: beats)
    }

    /// You pet, poke or shake it: its home feels it too.
    func felt(_ feeling: LinkFeeling) {
        guard visit?.isAwake == true else { return }
        app.link.felt(id, feeling)
    }

    /// A click: stops what it is doing, else a text box opens to ask it something.
    private func clickedVisitor() {
        touch()
        if [.thinking, .tools].contains(activity) { cancel(); react(.surprised, for: 0.6); return }
        if bubble?.phase == .typing { return dismissBubble() }
        startTyping()
    }

    /// It asked for something: the words go to its home, which answers (typed words only: the
    /// microphone, triggers and clipboard belong to the Mac that thinks).
    private func askHome(_ source: Source) {
        guard case .typed(let words, _) = source else { return }
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        touch()
        guard wakefulness.isAwake else { return refuseAsleep() }
        work = nil
        dropWork()
        app.link.ask(id, text)
        let heading = "“\(text)”"
        work = Work(ask: ChatTurn(request: text, via: .typed), heading: heading, title: "")
        thinking(heading, captions: Captions.thinking)
    }

    /// Why it is asleep and can't answer, in words that say what to do. Nil while it is awake.
    var sleepReason: String? {
        switch wakefulness {
        case .awake:
            return nil
        case .homeAway:
            let home = visit?.homeName ?? String(localized: "its home")
            return String(localized: "\(home) is away, so \(profile.name) can't think right now. It wakes up when \(home) is back.")
        case .noBrain:
            if let visit {
                return String(localized: "\(profile.name) has no brain yet, so it can't think. Give it one in its settings on \(visit.homeName).")
            }
            return app.assistant.problem(with: profile.brain, imp: profile.name)?.errorDescription
                ?? APIError.needsBrain(imp: profile.name).errorDescription
        }
    }

    /// Asked while it can't think: it stays asleep and says why, at once. (The chat says it in its
    /// own header, and its text box is off.)
    func refuseAsleep() {
        guard let reason = sleepReason else { return }
        guard !isChatting else { return }
        show(Bubble(title: String(localized: "\(profile.name) is asleep"), text: reason, phase: .hint,
                    link: visit == nil ? .settings : nil))
    }
}
