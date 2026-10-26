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

    @ObservationIgnored var onBubbleChange: (() -> Void)?
    @ObservationIgnored var onScaleChange: (() -> Void)?
    /// The view switched between resting (breath done by Core Animation) and drawing every frame.
    @ObservationIgnored var onRestingChange: ((Bool) -> Void)?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// The current bubble may time out (finished answers, hints and errors, unless shown to stay).
    @ObservationIgnored private var bubbleMayHide = false
    /// Its chats, kept across launches: the one you're in (what the chat shows, and what the
    /// model remembers of it) and the saved ones to go back to.
    private(set) var history: ChatHistory
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
    }
    private(set) var work: Work?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var streamShownAt = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "app.imp.Imp", category: "imp")

    static let sleepAfter: TimeInterval = 240

    init(id: UUID, app: AppModel) {
        self.id = id
        self.app = app
        clock = BodyClock(id)
        history = app.persists ? ChatHistory(folder: ChatHistory.folder(for: id))
                               : ChatHistory(folder: nil)
    }

    var profile: ImpProfile { app.prefs.imps.first { $0.id == id } ?? .imp }
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
        hideTask?.cancel()
        life.stop()
        started = false
        bubble = nil
    }

    func greetNewcomer() {
        show(Bubble(title: "Hi, I'm \(profile.name)", text: "Give me a brain (any OpenAI-compatible AI service) and we can chat. I can work your Mac too: ask me to open an app or fetch something.",
                    phase: .hint, link: .settings), autoHide: false)
        react(.happy, for: 2)
    }

    // MARK: Mood

    func mood(at date: Date) -> Mood {
        if let flash, flash.until > date { return flash.mood }
        if let activity { return activity.mood }
        if let m = life.step?.mood { return m }
        if date.timeIntervalSince(lastActivity) > Self.sleepAfter { return .sleepy }
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
        (flash.map { $0.until <= date } ?? true) && !isBusy && bubble == nil
            && date.timeIntervalSince(lastActivity) <= Self.sleepAfter
    }

    /// 0…1 "energy" for the current mood (mic loudness).
    var level: Double { activity == .listening ? micLevel : 0 }

    func react(_ mood: Mood, for seconds: Double) {
        if life.antic?.isWake == false { life.cancel() }
        flash = (mood, Date().addingTimeInterval(seconds))
    }

    func touch() {
        lastActivity = Date()
        if life.antic?.isWake == false { life.cancel() }
    }

    // MARK: Bubble

    private func show(_ b: Bubble, autoHide: Bool = true) {
        bubbleMayHide = autoHide
        bubble = b
        scheduleHide()
    }

    /// Only a finished bubble times out: never a text box, a listening or thinking bubble, or an
    /// answer still streaming in (hovering over and off those must not start the clock).
    private var bubbleCanTimeOut: Bool {
        guard bubbleMayHide, let b = bubble, !b.isStreaming, activity == nil else { return false }
        return [.result, .error, .hint].contains(b.phase)
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

    func pauseAutoHide() { hideTask?.cancel() }

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
        stopForChatChange()
        history.startNew()
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

    func renameChat(_ chat: UUID, to title: String) { history.rename(chat, to: title) }

    /// Deletes a chat for good: what was said, and the model's memory of it.
    func deleteChat(_ chat: UUID) {
        if chat == history.current.id { stopForChatChange() }
        history.delete(chat)
    }

    func deleteAllChats() {
        stopForChatChange()
        history.deleteAll()
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
    var canRecap: Bool { history.current.memory.exchangeCount > 1 && work == nil && !isRecapping }

    /// Has the model sum up the current chat, then forgets everything before the last exchange
    /// in favour of that recap (it shows in the chat; the turns above it stay there to read).
    /// For a chat that's grown too long for the model, or costly to send.
    func recapChat() {
        guard canRecap else { return }
        let chat = history.current.id
        let request = Recap.request(history.current.memory, name: profile.name)
        isRecapping = true
        recapError = nil
        recapTask = Task { [weak self, brain = profile.brain] in
            guard let self else { return }
            defer { self.isRecapping = false }
            do {
                let (summary, _) = try await self.app.assistant.chat(request, brain: brain, tools: nil)
                try Task.checkCancellation()
                guard self.history.current.id == chat else { return }
                self.history.recap(summary)
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
    private func record(_ ask: ChatTurn?, reply: String, failed: Bool = false, exchange: [ChatMessage]? = nil) {
        guard var turn = ask else { return }
        turn.reply = reply
        turn.failed = failed
        turn.steps = finishedSteps.compactMap(\.saved)
        if isChatting && !failed { freshTurns.insert(turn.id) }
        history.append(turn, remembering: exchange)
    }

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
        if let w = work { record(w.ask, reply: "Stopped before answering.", failed: true) }
        work = nil
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

    /// A click on this Imp: stops whatever it's doing, else types or talks (Settings › Look & Feel).
    func click(alternate: Bool = false) {
        touch()
        app.focus(self)
        if app.finishListening(for: self) { return }
        if [.thinking, .tools].contains(activity) { cancel(); react(.surprised, for: 0.6); return }
        let action = alternate ? (prefs.click == .type ? ClickAction.talk : .type) : prefs.click
        switch action {
        case .type: bubble?.phase == .typing ? dismissBubble() : startTyping()
        case .talk: talk()
        }
    }

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
        touch()
        app.focus(self)
        cancel()
        setActivity(.typing)
        show(Bubble(text: prefill, phase: .typing, prompt: prompt ?? "Ask \(profile.name) anything…"), autoHide: false)
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

    /// The bubble has a text box: the typing bubble, or the chat.
    private var takesTyping: Bool { bubble?.phase == .typing || isChatting }

    /// Something pasted into the text box (⌘V or ⌃V): a picture rides along with the message.
    /// Returns false when there's no text box to take it.
    @discardableResult
    func attach(_ picture: EncodedImage) -> Bool {
        guard var b = bubble, takesTyping else { return false }
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

    /// A shortcut: its instruction, with what's on the clipboard (or `clip`, from a URL command)
    /// unless it sends the instruction alone.
    func run(_ shortcut: Shortcut, clip given: Clip? = nil) {
        touch()
        app.focus(self)
        if let given { return start(.shortcut(shortcut, given)) }
        guard shortcut.usesClipboard else { return start(.shortcut(shortcut, nil)) }
        guard let clip = Pasteboard.clip() else { return nothingCopied(shortcut) }
        start(.shortcut(shortcut, clip))
    }

    /// A question from another app (URL command).
    func ask(_ text: String) {
        start(.typed(text, nil))
    }

    /// Something went wrong outside a request (an unknown shortcut name from a URL command).
    func complain(_ text: String) {
        react(.error, for: 1.5)
        show(Bubble(title: "Hmm", text: text, phase: .error))
    }

    /// Four quick clicks: whatever animation answers to pokes (a tantrum, out of the box).
    func flurry() {
        touch()
        // The first click opened a text box. A poking spree isn't a conversation.
        stopWaitingForUser()
        guard let reaction = prefs.animation(for: .poke) else { return }
        cancel()
        app.reactions.play(reaction, by: self)
        guard reaction == .angry else { return }
        let lines = ["Poke me again and I'll translate your diary into Klingon.", "I bite. Metaphorically. Mostly.",
                     "I'm a demon, not a stress ball.", "Careful. My horns are still growing."]
        show(Bubble(title: "Ow", text: lines.randomElement()!, phase: .hint))
    }

    /// A double-click opens this Imp's settings (and closes a text box or listening bubble left open).
    func doubleClicked() {
        guard prefs.doubleClickOpensSettings else { return }
        stopWaitingForUser()
        HomeWindow.shared.show(app, settingsFor: id, tab: isReady ? nil : .brain)
    }

    // MARK: Pipeline

    /// Where a request comes from. Every one goes the same way: the Imp's model gets the words
    /// (and any picture) with its tools, and decides what to do.
    enum Source {
        /// Typed into the bubble (with a pasted picture, maybe), or sent by another app.
        case typed(String, EncodedImage?)
        /// Said out loud: listen first.
        case spoken
        /// A shortcut's instruction, with what was copied (nil: the instruction alone).
        case shortcut(Shortcut, Clip?)
    }

    private func start(_ source: Source) {
        touch()
        app.focus(self)
        cancel()
        recapTask?.cancel()                           // a new turn would slip past the recap
        job = Task { await run(source) }
    }

    private func nothingCopied(_ shortcut: Shortcut) {
        react(.sad, for: 1.8)
        let keys = shortcut.hotkey.map { " then press \($0.displayString) again" } ?? ""
        show(Bubble(title: shortcut.name, text: "Your clipboard is empty. Copy some text or a picture first,\(keys).", phase: .hint))
    }

    private func run(_ source: Source) async {
        var title = ""
        /// What you asked, for the history (nil until there's something to answer).
        var ask: ChatTurn?
        do {
            let turn: ChatMessage, heading: String
            switch source {
            case .typed(let words, let picture):
                let path = picture.flatMap(save)
                turn = Briefing.message(words, image: picture, imagePath: path)
                heading = words.isEmpty ? "A picture" : "“\(words)”"
                ask = ChatTurn(request: words, via: .typed, picture: path)
            case .spoken:
                let words = try await listen()
                turn = Briefing.message(words)
                heading = "“\(words)”"
                ask = ChatTurn(request: words, via: .spoken)
            case .shortcut(let shortcut, let clip):
                title = shortcut.name
                var path: String?
                if case .image(let picture)? = clip { path = save(picture) }
                turn = Briefing.shortcut(shortcut.prompt, clip: clip, imagePath: path)
                heading = shortcut.name
                let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                var copied: String?
                if case .text(let text)? = clip { copied = text }
                ask = ChatTurn(request: shortcut.name, via: .shortcut, instruction: instruction.isEmpty ? nil : instruction,
                               copiedText: copied, picture: path)
            }
            work = ask.map { Work(ask: $0, heading: heading, title: title) }
            log.info("\(self.profile.name, privacy: .public) works on “\(title.isEmpty ? "a message" : title, privacy: .public)”")
            thinking(heading, captions: Captions.thinking)
            let tools = app.assistant.tools(for: profile)
            if app.assistant.toolsConnecting { addStep(.wakingUp) }
            let (reply, exchange) = try await app.assistant.chat(messages(with: turn), brain: profile.brain, tools: tools,
                                                                 stream: true) { [weak self] event in
                self?.progress(event, title: title)
            }
            try Task.checkCancellation()
            record(ask, reply: reply, exchange: exchange)
            showAnswer(reply, title: title)
        } catch is CancellationError {
            dropWork()
        } catch let error as Dictation.Failure where error == .heardNothing {
            // Offer the keyboard instead of a dead end.
            react(.sad, for: 1.2)
            startTyping(prompt: "I didn't catch that. Type it?")
        } catch {
            guard !Task.isCancelled else { return }
            record(ask, reply: error.localizedDescription, failed: true)
            fail(title.isEmpty ? "thinking" : title, error)
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
    private func messages(with turn: ChatMessage) -> [ChatMessage] {
        let p = profile
        try? FileManager.default.createDirectory(at: p.workspace, withIntermediateDirectories: true)
        return history.current.memory.context(system: p.systemPrompt, turn: turn,
                                              exchanges: p.memoryExchanges, tools: p.remembersToolCalls)
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
        react(.error, for: 2.2)
        app.stage.broadcast(.failed, from: self)
        // Setup problems point at the Brain tab and stay until dealt with.
        let needsSetup = switch error as? APIError {
        case .missingKey?, .noService?, .noModel?: true
        default: false
        }
        work = nil
        let failure = Bubble(title: "Oops: \(what)", text: error.localizedDescription, phase: .error,
                             link: needsSetup ? .settings : nil)
        // In the chat: it shows there, and comes up when you go back.
        if bubble?.phase == .chat { beforeChat = failure } else { show(failure, autoHide: !needsSetup) }
    }

    /// The finished answer: the bubble the stream was filling (same bubble, now with its buttons),
    /// and a happy bounce.
    private func showAnswer(_ text: String, title: String) {
        setActivity(nil)
        captionTask?.cancel()
        react(.happy, for: 1.0)
        app.stage.broadcast(.answered, from: self)
        let streaming = bubble?.isStreaming == true ? bubble : nil
        // The turn's id when it has none yet: media the chat already autoplayed won't play again here.
        let answer = Bubble(id: streaming?.id ?? work?.ask.id ?? UUID(), title: title, text: text, phase: .result, steps: finishedSteps)
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
        show(Bubble(title: title, text: shuffled[0], phase: .thinking), autoHide: false)
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
        for i in w.steps.indices where w.steps[i].icon == Bubble.Step.wakingUp.icon { w.steps[i].state = .done }
        w.steps.append(step)
        work = w
        showSteps()
    }

    /// A thinking bubble shows the work's steps (the history reads them from `work` itself).
    private func showSteps() {
        guard var b = bubble, b.phase == .thinking, let work else { return }
        b.steps = work.steps
        bubble = b
    }

    private func progress(_ event: AgentEvent, title: String) {
        switch event {
        case .text(let text):
            stream(text, title: title)
        case .toolStarted(let name, let arguments):
            stopStreaming()
            setActivity(.tools)
            let label = ToolLabel(tool: name, arguments: arguments)
            addStep(Bubble.Step(icon: label.icon, title: label.title, tool: name, request: label.request))
        case .toolFinished(let name, let ok, let result):
            guard var w = work, let i = w.steps.lastIndex(where: { $0.tool == name && $0.state == .running }) else { return }
            w.steps[i].state = ok ? .done : .failed
            w.steps[i].response = Bubble.Step.clipped(result)
            work = w
            showSteps()
            setActivity(.thinking)                     // back to the model with the result
        }
    }

    /// Steps of the finished job, with anything still running marked done.
    private var finishedSteps: [Bubble.Step] {
        (work?.steps ?? []).map { var s = $0; if s.state == .running { s.state = .done }; return s }
    }

    private func caption(_ text: String) {
        guard var b = bubble, b.phase == .thinking else { return }
        b.text = text
        bubble = b
    }
}
