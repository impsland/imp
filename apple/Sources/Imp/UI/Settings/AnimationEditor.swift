import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// An animation being made or changed in the editor.
struct AnimationDraft: Identifiable {
    let id = UUID()
    var made: MadeAnimation
    /// Who it's for: one Imp, or nil for every Imp.
    var owner: UUID?
    var isNew: Bool
    /// The Imp that acts it out in the editor (the window's selection, or the Imp whose settings opened
    /// it): the one Imp "For" offers besides every Imp. Saving a shared one for it makes its own version.
    var previewImp: UUID?

    /// A new animation of its own: a little hop and a smile to start from.
    @MainActor static func new(owner: UUID?, model: AppModel, previewImp: UUID? = nil) -> AnimationDraft {
        let name = model.prefs.uniqueAnimationName(String(localized: "My animation"), imp: owner)
        let beats = [AnimationBeat(duration: 0.5, lookX: 0, lookY: 0.1, mood: "excited", hop: true),
                     AnimationBeat(duration: 0.9, lookX: 0.2, lookY: -0.1, mood: "happy", tilt: 6),
                     AnimationBeat(duration: 0.6, lookX: 0, lookY: 0.1, mood: "content")]
        return AnimationDraft(made: MadeAnimation(name: name, beats: beats), owner: owner, isNew: true,
                              previewImp: previewImp ?? owner)
    }

    /// A new version of a built-in animation, starting from its beats exactly as they are.
    @MainActor static func replacing(_ reaction: Reaction, owner: UUID?, model: AppModel, previewImp: UUID? = nil) -> AnimationDraft {
        let beats = reaction.beats
        return AnimationDraft(made: MadeAnimation(name: "", about: reaction.summary, symbol: reaction.symbol, replaces: reaction, beats: beats),
                              owner: owner, isNew: true, previewImp: previewImp ?? owner)
    }

    init(made: MadeAnimation, owner: UUID?, isNew: Bool, previewImp: UUID? = nil) {
        self.made = made; self.owner = owner; self.isNew = isNew; self.previewImp = previewImp ?? owner
    }
}

/// The animation editor, laid out like an editor: the stage on the left (drag on it to turn the
/// face), the picked beat's pose on the right, and the timeline along the bottom (drag a beat to
/// move it, drag its right edge to make it longer or shorter, click the ruler to play from there).
/// The name, icon and who it's for come after, on Save. Every built-in animation opens here too
/// (as a new version of itself), so nothing is simplified on the way in.
struct AnimationEditor: View {
    let model: AppModel
    @State private var draft: AnimationDraft
    @State private var selected = 0
    @State private var page = Page.edit
    @State private var playing: Performance?
    @State private var loops = false
    /// When the beat on the stage started (a new pick, or a changed move, plays its move once).
    @State private var holdStarted = Date()
    /// Undo: earlier versions of the beats, and the ones undone.
    @State private var history = BeatHistory()
    /// A copied pose, to paste onto another beat.
    @State private var copied: AnimationBeat?
    @State private var zoom: CGFloat = 1
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page { case edit, details }

    init(model: AppModel, draft: AnimationDraft, page: Page = .edit) {
        self.model = model
        _draft = State(initialValue: draft)
        _page = State(initialValue: page)
    }

    private var animation: MadeAnimation { draft.made }
    private var beats: [AnimationBeat] { draft.made.beats }
    private var actor: ImpProfile? { (draft.owner ?? draft.previewImp).flatMap(model.profile) ?? model.prefs.imps.first }
    private var hue: Double { actor?.hue ?? 0 }
    private var traits: ImpTraits { actor?.traits ?? .plain }
    private var tint: Color { Color.imp(hue) }

    var body: some View {
        SheetScaffold(icon: animation.symbol, title: title, info: info, width: Sizing.editorWidth) {
            HStack(spacing: Spacing.hairline) {
                if page == .edit {
                    HoverIconButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)") { undo() }
                        .keyboardShortcut("z", modifiers: .command).disabled(!history.canUndo)
                    HoverIconButton(systemName: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!history.canRedo)
                    if !draft.isNew {
                        HoverIconButton(systemName: "pencil.line", help: "Name, icon and who it's for") { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { page = .details } }
                    }
                }
                ShareKitButton(kit: Kit(name: animation.title, animations: [animation.normalized]), help: "Share this animation as a kit")
            }
        } content: {
            switch page {
            case .edit: editor
            case .details: details
            }
        } footer: {
            footer
        }
        .environment(\.impTint, tint)
        .tint(tint)
        .onChange(of: selected) { holdStarted = Date() }
        .onChange(of: beats) { old, _ in remember(old) }
    }

    private var title: LocalizedStringKey {
        if page == .details { return draft.isNew ? "Almost done" : "Details" }
        if let r = animation.replaces { return draft.isNew ? "Your own \(r.title)" : "Change \(r.title)" }
        return draft.isNew ? "animations.new" : "Change \(animation.title)"
    }

    private var info: LocalizedStringKey {
        page == .details
            ? "What it's called, its icon in the list, and which Imps play it."
            : "Beats play one after another. Each holds a pose: a mood, where the face turns, a tilt, a shape, a move, a symbol, a hop. Space plays, ⌘Z undoes, ←→ pick a beat, ⌫ removes it."
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch page {
        case .edit:
            if !draft.isNew {
                Button(animation.replaces == nil ? "Delete" : "Restore Original", role: .destructive) {
                    model.prefs.removeAnimation(animation.id)
                    dismiss()
                }
                .buttonStyle(.imp(.destructive, small: true))
                .help(animation.replaces == nil ? "Removes this animation" : "Removes your version: the built-in one plays again")
            }
            Spacer()
            if draft.isNew {
                Button("Save…") { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { page = .details } }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(beats.isEmpty)
                    .help("Name it, then save it")
            } else {
                Button("Save") { save() }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        case .details:
            Button { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { page = .edit } } label: { Label("Back to Editing", systemImage: "chevron.left") }
                .buttonStyle(.quiet)
            Spacer()
            Button("Save") { save() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        !beats.isEmpty && (animation.replaces != nil || !animation.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: The editor

    private var editor: some View {
        VStack(spacing: Spacing.small) {
            HStack(alignment: .top, spacing: Spacing.medium) {
                stagePanel.frame(width: Sizing.stageWidth)
                inspector
            }
            .frame(height: Sizing.editorTop)
            timeline
        }
        .background { shortcuts }
    }

    /// Keys for the timeline that have no button of their own.
    private var shortcuts: some View {
        ZStack {
            Button(String("")) { pick(selected - 1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button(String("")) { pick(selected + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button(String("")) { remove() }.keyboardShortcut(.delete, modifiers: [])
            Button(String("")) { duplicate() }.keyboardShortcut("d", modifiers: .command)
            Button(String("")) { copyPose() }.keyboardShortcut("c", modifiers: .command)
            Button(String("")) { pastePose() }.keyboardShortcut("v", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Stage

    private var stagePanel: some View {
        VStack(spacing: 0) {
            LookStage(hue: hue, traits: traits, performance: playing ?? holding, beat: playing == nil ? beatIfAny : nil,
                      onLook: { x, y in
                          playing = nil
                          beat.wrappedValue.lookX = x
                          beat.wrappedValue.lookY = y
                      })
                .task(id: playing?.started) {
                    guard let p = playing else { return }
                    let left = p.started.addingTimeInterval(p.duration + 0.35).timeIntervalSinceNow
                    try? await Task.sleep(for: .seconds(max(0, left)))
                    guard playing == p else { return }
                    playing = loops ? performance() : nil
                }
            transport
        }
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.well))
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    private var transport: some View {
        HStack(spacing: Spacing.tight) {
            Button { playing = playing == nil ? performance() : nil } label: {
                Image(systemName: playing == nil ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.imp(.secondary, small: true))
            .keyboardShortcut(.space, modifiers: [])
            .help(playing == nil ? "Play it from the start (Space)" : "Stop (Space)")
            .accessibilityLabel(playing == nil ? "Play" : "Stop")
            Toggle(isOn: $loops) { Image(systemName: "repeat") }
                .toggleStyle(.impButton)
                .help("Play it again and again")
            HoverIconButton(systemName: "arrow.counterclockwise", help: "Play this beat again") {
                playing = nil
                holdStarted = Date()
            }
            Spacer(minLength: Spacing.tight)
            clock
        }
        .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.snug)
        .background(Tone.well)
    }

    /// Where it's at: the time while it plays, else the picked beat's start, and the whole length.
    private var clock: some View {
        let total = beats.reduce(0) { $0 + $1.duration }
        return TimelineView(.animation(minimumInterval: Energy.shared.interval(fps: 15), paused: playing == nil)) { tl in
            let now = playing.map { min(total, tl.date.timeIntervalSince($0.started) * traits.tempo) }
                ?? beats.prefix(selected).reduce(0) { $0 + $1.duration }
            Text(verbatim: String(format: "%.2f / %.2f s", now, total))
                .font(Typeface.small.weight(.medium).monospacedDigit())
                .foregroundStyle(total > MadeAnimation.maxDuration ? Tone.warnText : Tone.muted)
        }
        .help(total > MadeAnimation.maxDuration
              ? Text("Over \(Int(MadeAnimation.maxDuration)) s. Beats are shortened when saved.")
              : Text("How long it plays (\(actor?.callName ?? "the Imp") plays it at its own pace)"))
    }

    /// The whole animation, at the pace of the Imp acting it out, from `time` seconds in.
    private func performance(from time: Double = 0) -> Performance {
        let tempo = max(0.1, traits.tempo)
        return Performance(key: "draft", steps: Antics.paced(beats.map(AnticStep.init), tempo: tempo),
                           at: Date().addingTimeInterval(-time / tempo))
    }

    /// The picked beat on the stage: played once (its hop and move), then held.
    private var holding: Performance? {
        guard let b = beatIfAny else { return nil }
        let step = AnticStep(b)
        var hold = step
        hold.duration = 3600
        hold.hop = false
        hold.move = nil
        return Performance(key: "hold", steps: Antics.paced([step], tempo: max(0.1, traits.tempo)) + [hold], at: holdStarted)
    }

    private var beatIfAny: AnimationBeat? { beats.indices.contains(selected) ? beats[selected] : nil }

    // MARK: The picked beat

    private var beat: Binding<AnimationBeat> {
        Binding(get: { beatIfAny ?? AnimationBeat(duration: 0.5) },
                set: { if draft.made.beats.indices.contains(selected) { draft.made.beats[selected] = $0 } })
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: "slider.horizontal.3").font(.icon(.medium, weight: .semibold)).foregroundStyle(LegibleTint(tint))
                Text("Beat \(selected + 1) of \(beats.count)").font(Typeface.cardTitle)
                Spacer()
                HoverIconButton(systemName: "chevron.left", help: "The beat before (←)") { pick(selected - 1) }.disabled(selected <= 0)
                HoverIconButton(systemName: "chevron.right", help: "The beat after (→)") { pick(selected + 1) }.disabled(selected >= beats.count - 1)
            }
            .padding(.horizontal, Spacing.medium).padding(.top, Spacing.snug).padding(.bottom, Spacing.snug)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Spacing.snug) { fields }
                    .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    @ViewBuilder private var fields: some View {
        FieldRow("Length", info: "anim.help.length") {
            HStack(spacing: Spacing.small) {
                Slider(value: Binding(get: { beat.wrappedValue.duration },
                                      set: { beat.wrappedValue.duration = max(0.05, ($0 * 20).rounded() / 20) }),
                       in: AnimationBeat.durationRange)
                    .impSlider()
                Text(verbatim: Self.seconds(beat.wrappedValue.duration))
                    .font(Typeface.small.weight(.medium).monospacedDigit())
                    .frame(width: BubbleMetrics.transport, alignment: .trailing)
            }
        }
        FieldRow("Hop", info: "anim.help.hop") {
            Toggle("Hop", isOn: Binding(get: { beat.wrappedValue.hop }, set: { beat.wrappedValue.hop = $0; if $0 { replayBeat() } }))
                .labelsHidden().toggleStyle(.impSwitchBare)
        }
        FieldRow("Mood", info: "How it feels during this beat. Keep: whatever it feels anyway.") {
            MoodPicker(mood: beat.mood, hue: hue)
        }
        FieldRow("Look", info: "Drag on the stage to turn its face. Double-click to face you.") {
            HStack(spacing: Spacing.small) {
                Toggle("Turns its face", isOn: Binding(
                    get: { beat.wrappedValue.hasLook },
                    set: { on in
                        beat.wrappedValue.lookX = on ? 0 : nil
                        beat.wrappedValue.lookY = on ? 0.1 : nil
                    }))
                    .toggleStyle(.impSwitch).fixedSize().font(Typeface.body)
                Spacer(minLength: 0)
                Button { beat.wrappedValue.lookX = 0; beat.wrappedValue.lookY = 0.1 } label: { FitLabel("At You", systemImage: "scope") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Turn its face to you")
            }
        }
        FieldRow("Tilt", info: "anim.help.tilt") {
            CompactSlider(value: beat.tilt, range: AnimationBeat.tiltRange, format: { "\(Int($0.rounded()))°" })
        }
        FieldRow("Shape", info: "anim.help.shape") {
            CompactSlider(value: beat.stretch, range: AnimationBeat.stretchRange, format: { String(format: "%+.2f", $0) })
        }
        FieldRow("Move", info: "A move played across the whole beat. Give it time: a spin or a flip looks best at 0.8 s or more.") {
            MovePicker(beat: beat, replay: replayBeat)
        }
        FieldRow("Symbol", info: "anim.help.symbol") {
            GlyphPicker(glyph: beat.glyph)
        }
    }

    private func replayBeat() {
        playing = nil
        holdStarted = Date()
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Text("Beats").font(Typeface.cardTitle)
                InfoTip("anim.help.beats")
                Text(verbatim: "\(beats.count)/\(MadeAnimation.maxBeats)").font(Typeface.small.weight(.medium)).foregroundStyle(Tone.muted)
                Spacer()
                HoverIconButton(systemName: "minus.magnifyingglass", help: "Zoom out") { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { zoom = max(0.5, zoom / 1.4) } }
                    .disabled(zoom <= 0.5)
                HoverIconButton(systemName: "plus.magnifyingglass", help: "Zoom in") { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { zoom = min(3, zoom * 1.4) } }
                    .disabled(zoom >= 3)
                HoverIconButton(systemName: "scissors", help: "Split the beat in two") { split() }
                    .disabled(beats.count >= MadeAnimation.maxBeats || (beatIfAny?.duration ?? 0) < 0.1)
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate the beat (⌘D)") { duplicate() }
                    .disabled(beats.count >= MadeAnimation.maxBeats || beats.isEmpty)
                HoverIconButton(systemName: "trash", help: "Remove the beat (⌫)") { remove() }.disabled(beats.count <= 1)
                Button { add() } label: { FitLabel("Beat", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(beats.count >= MadeAnimation.maxBeats)
                    .help("Add a beat after this one")
            }
            BeatTrack(beats: $draft.made.beats, selected: $selected, hue: hue, zoom: zoom, playing: playing, tempo: traits.tempo,
                      copied: copied != nil,
                      onPlay: { t in playing = performance(from: t) },
                      onAdd: { add() }, onDuplicate: { duplicate() }, onSplit: { split() }, onRemove: { remove() },
                      onCopy: { copyPose() }, onPaste: { pastePose() })
        }
        .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
    }

    private func pick(_ i: Int) {
        guard beats.indices.contains(i) else { return }
        withImpAnimation(ImpDesign.Motion.press, reduceMotion: reduceMotion) { selected = i }
    }

    /// Applies a timeline edit to the draft's beats and the picked one.
    private func edit(_ change: (inout BeatList) -> Void) {
        var list = BeatList(beats: draft.made.beats, selected: selected)
        change(&list)
        draft.made.beats = list.beats
        selected = list.selected
    }

    private func add() { edit { $0.add() } }

    private func duplicate() { edit { $0.duplicate() } }

    private func split() { edit { $0.split() } }

    private func remove() { edit { $0.remove() } }

    private func copyPose() { copied = beatIfAny }

    private func pastePose() {
        guard let pose = copied else { return }
        var pasted = false
        edit { pasted = $0.paste(pose) }
        if pasted { replayBeat() }
    }

    // MARK: Undo

    private func remember(_ old: [AnimationBeat]) { history.remember(old) }

    private func undo() { if let list = history.undo(current: beats) { restore(list) } }

    private func redo() { if let list = history.redo(current: beats) { restore(list) } }

    private func restore(_ list: [AnimationBeat]) {
        draft.made.beats = list
        selected = min(selected, max(0, list.count - 1))
    }

    // MARK: Details

    private var details: some View {
        HStack(alignment: .top, spacing: Spacing.large) {
            VStack(spacing: Spacing.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.well)
                    StageImp(hue: hue, performance: playing, traits: traits)
                        .frame(width: Sizing.column / 4 - Spacing.large, height: Sizing.column / 4 - Spacing.large)
                }
                .onAppear { playing = performance() }
                .frame(width: Sizing.column / 4, height: Sizing.column / 4)
                .onTapGesture { playing = performance() }
                .help("Click to play it again")
                HStack(spacing: Spacing.tight) {
                    Text("\(beats.count) beats · \(Self.seconds(beats.reduce(0) { $0 + $1.duration }))")
                        .font(Typeface.small.weight(.medium).monospacedDigit()).foregroundStyle(Tone.muted)
                    if !traits.isPlain {
                        InfoTip(verbatim: String(localized: "\(actor?.callName ?? "") plays it with its own character: \(traits.summary.lowercased())."))
                    }
                }
            }
            VStack(alignment: .leading, spacing: Spacing.medium) {
                if let r = animation.replaces {
                    FieldRow("Plays", info: "anim.help.plays") {
                        Label("Instead of \(r.title)", systemImage: "arrow.triangle.swap")
                            .font(Typeface.caption).foregroundStyle(Tone.text)
                    }
                } else {
                    FieldRow("common.name", info: "anim.help.name") {
                        TextField("What is it called?", text: $draft.made.name).impField()
                    }
                }
                FieldRow("About", info: "anim.help.about") {
                    TextField("What it looks like, in a few words", text: $draft.made.about).impField()
                }
                FieldRow("For", info: "One made for a single Imp plays only for it, in place of a shared one.") {
                    ImpPicker("For", selection: $draft.owner, options: [UUID?.none] + [draft.previewImp].compactMap { $0 }.map { Optional($0) }) { owner in
                        guard let owner, let imp = model.prefs.imps.first(where: { $0.id == owner }) else { return String(localized: "Every Imp") }
                        return String(localized: "\(imp.callName) only")
                    }
                }
                FieldRow("Icon", info: "anim.help.icon") { IconPicker(symbol: $draft.made.symbol, extra: animation.replaces?.symbol) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func seconds(_ s: Double) -> String { String(format: "%.2f s", s) }

    private func save() {
        var a = draft.made
        if a.replaces == nil {
            a.name = model.prefs.uniqueAnimationName(a.name, imp: draft.owner, except: a.id)
        }
        withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { _ = model.prefs.save(a, for: draft.owner) }
        dismiss()
    }
}
