import AppKit
import ImpKit
import SwiftUI

/// An animation being made or changed in the editor.
struct AnimationDraft: Identifiable {
    let id = UUID()
    var made: MadeAnimation
    /// Who it's for: one Imp, or nil for every Imp.
    var owner: UUID?
    var isNew: Bool
    /// The Imp that acts it out in the editor when it's for every Imp (the window's selection).
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
        let beats = Antics.steps(for: reaction, work: .zero).map(AnimationBeat.init)
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
    @State private var history: [[AnimationBeat]] = []
    @State private var future: [[AnimationBeat]] = []
    @State private var lastEdit = Date.distantPast
    @State private var restoring = false
    /// A copied pose, to paste onto another beat.
    @State private var copied: AnimationBeat?
    @State private var zoom: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

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
        SheetScaffold(icon: animation.symbol, title: title, info: info, width: 780) {
            HStack(spacing: 2) {
                if page == .edit {
                    HoverIconButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)") { undo() }
                        .keyboardShortcut("z", modifiers: .command).disabled(history.isEmpty)
                    HoverIconButton(systemName: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(future.isEmpty)
                    if !draft.isNew {
                        HoverIconButton(systemName: "pencil.line", help: "Name, icon and who it's for") { withAnimation(.snappy) { page = .details } }
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
        return draft.isNew ? "New Animation" : "Change \(animation.title)"
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
            SheetCancelButton { dismiss() }
            if draft.isNew {
                Button("Save…") { withAnimation(.snappy) { page = .details } }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(beats.isEmpty)
                    .help("Name it, then save it")
            } else {
                Button("Save") { save() }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        case .details:
            Button { withAnimation(.snappy) { page = .edit } } label: { Label("Back to Editing", systemImage: "chevron.left") }
                .buttonStyle(.quiet)
            Spacer()
            SheetCancelButton { dismiss() }
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
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                stagePanel.frame(width: 268)
                inspector
            }
            .frame(height: Self.topHeight)
            timeline
        }
        .background { shortcuts }
    }

    private static let topHeight: CGFloat = 282

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
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Button { playing = playing == nil ? performance() : nil } label: {
                Image(systemName: playing == nil ? "play.fill" : "stop.fill").frame(width: 16)
            }
            .buttonStyle(.imp(.secondary, small: true))
            .keyboardShortcut(.space, modifiers: [])
            .help(playing == nil ? "Play it from the start (Space)" : "Stop (Space)")
            .accessibilityLabel(playing == nil ? "Play" : "Stop")
            Toggle(isOn: $loops) { Image(systemName: "repeat") }
                .toggleStyle(.button).controlSize(.small)
                .help("Play it again and again")
            HoverIconButton(systemName: "arrow.counterclockwise", help: "Play this beat again") {
                playing = nil
                holdStarted = Date()
            }
            Spacer(minLength: 4)
            clock
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { CardDivider() }
    }

    /// Where it's at: the time while it plays, else the picked beat's start, and the whole length.
    private var clock: some View {
        let total = beats.reduce(0) { $0 + $1.duration }
        return TimelineView(.animation(minimumInterval: 1 / 15, paused: playing == nil)) { tl in
            let now = playing.map { min(total, tl.date.timeIntervalSince($0.started) * traits.tempo) }
                ?? beats.prefix(selected).reduce(0) { $0 + $1.duration }
            Text(verbatim: String(format: "%.2f / %.2f s", now, total))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(total > MadeAnimation.maxDuration ? Color.orange : Dungeon.muted)
        }
        .help(total > MadeAnimation.maxDuration
              ? Text("Longer than \(Int(MadeAnimation.maxDuration)) s: every beat is shortened alike when it's saved.")
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
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text("Beat \(selected + 1) of \(beats.count)").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                HoverIconButton(systemName: "chevron.left", help: "The beat before (←)") { pick(selected - 1) }.disabled(selected <= 0)
                HoverIconButton(systemName: "chevron.right", help: "The beat after (→)") { pick(selected + 1) }.disabled(selected >= beats.count - 1)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            CardDivider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 9) { fields }
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    private static let label: CGFloat = 60

    @ViewBuilder private var fields: some View {
        FieldRow("Length", width: Self.label) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { beat.wrappedValue.duration },
                                      set: { beat.wrappedValue.duration = max(0.05, ($0 * 20).rounded() / 20) }),
                       in: AnimationBeat.durationRange)
                    .help("Or drag the right edge of the beat on the timeline (hold ⌥ for finer steps)")
                Text(verbatim: Self.seconds(beat.wrappedValue.duration))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                Toggle("Hop", isOn: Binding(get: { beat.wrappedValue.hop }, set: { beat.wrappedValue.hop = $0; if $0 { replayBeat() } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                    .help("A hop as the beat starts (it takes 0.75 s)")
            }
        }
        FieldRow("Mood", info: "How it feels during this beat. Keep: whatever it feels anyway.", width: Self.label) {
            MoodPicker(mood: beat.mood, hue: hue)
        }
        FieldRow("Look", info: "Drag on the stage to turn its face; double-click it to look at you. Off: it follows the cursor (or its mood decides).", width: Self.label) {
            HStack(spacing: 8) {
                Toggle("Turns its face", isOn: Binding(
                    get: { beat.wrappedValue.hasLook },
                    set: { on in
                        beat.wrappedValue.lookX = on ? 0 : nil
                        beat.wrappedValue.lookY = on ? 0.1 : nil
                    }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                Text(beat.wrappedValue.hasLook ? "Drag on the stage" : "Follows the cursor")
                    .font(.system(size: 11)).foregroundStyle(Dungeon.muted).lineLimit(1)
                Spacer(minLength: 0)
                Button("At You") { beat.wrappedValue.lookX = 0; beat.wrappedValue.lookY = 0.1 }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Turn its face to you")
            }
        }
        FieldRow("Tilt", width: Self.label) {
            HStack(spacing: 10) {
                CompactSlider(value: beat.tilt, range: AnimationBeat.tiltRange, format: { "\(Int($0.rounded()))°" })
                    .help("− leans left, + leans right. Double-click to straighten.")
                Text("Shape").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Dungeon.muted).lineLimit(1)
                CompactSlider(value: beat.stretch, range: AnimationBeat.stretchRange, format: { String(format: "%+.2f", $0) })
                    .help("− squishes flat, + stands tall and thin. Double-click to reset.")
            }
        }
        FieldRow("Move", info: "A move played across the whole beat. Give it time: a spin or a flip looks best at 0.8 s or more.", width: Self.label) {
            MovePicker(beat: beat, replay: replayBeat)
        }
        FieldRow("Symbol", width: Self.label) {
            GlyphPicker(glyph: beat.glyph)
        }
    }

    private func replayBeat() {
        playing = nil
        holdStarted = Date()
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Beats").font(.system(size: 13, weight: .bold, design: .rounded))
                Text(verbatim: "\(beats.count)/\(MadeAnimation.maxBeats)").font(.system(size: 11, weight: .medium)).foregroundStyle(Dungeon.muted)
                Spacer()
                HoverIconButton(systemName: "minus.magnifyingglass", help: "Zoom out") { withAnimation(.snappy) { zoom = max(0.5, zoom / 1.4) } }
                    .disabled(zoom <= 0.5)
                HoverIconButton(systemName: "plus.magnifyingglass", help: "Zoom in") { withAnimation(.snappy) { zoom = min(3, zoom * 1.4) } }
                    .disabled(zoom >= 3)
                Divider().frame(height: 14).padding(.horizontal, 2)
                HoverIconButton(systemName: "scissors", help: "Split the beat in two") { split() }
                    .disabled(beats.count >= MadeAnimation.maxBeats || (beatIfAny?.duration ?? 0) < 0.1)
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate the beat (⌘D)") { duplicate() }
                    .disabled(beats.count >= MadeAnimation.maxBeats || beats.isEmpty)
                HoverIconButton(systemName: "trash", help: "Remove the beat (⌫)") { remove() }.disabled(beats.count <= 1)
                Button { add() } label: { Label("Beat", systemImage: "plus") }
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }

    private func pick(_ i: Int) {
        guard beats.indices.contains(i) else { return }
        withAnimation(.snappy(duration: 0.15)) { selected = i }
    }

    private func add() {
        guard beats.count < MadeAnimation.maxBeats else { return }
        var b = beatIfAny ?? AnimationBeat(duration: 0.5)
        b.hop = false
        b.glyph = nil
        b.move = nil; b.times = nil; b.reverse = nil
        let at = min(selected + 1, beats.count)
        draft.made.beats.insert(b, at: at)
        selected = at
    }

    private func duplicate() {
        guard let b = beatIfAny, beats.count < MadeAnimation.maxBeats else { return }
        draft.made.beats.insert(b, at: selected + 1)
        selected += 1
    }

    /// Two halves of the picked beat; a hop stays with the first, a move is split between them.
    private func split() {
        guard var a = beatIfAny, beats.count < MadeAnimation.maxBeats, a.duration >= 0.1 else { return }
        let half = AnimationBeat.round(a.duration / 2)
        var b = a
        a.duration = half
        b.duration = AnimationBeat.round(max(0.05, b.duration - half))
        b.hop = false
        draft.made.beats[selected] = a
        draft.made.beats.insert(b, at: selected + 1)
    }

    private func remove() {
        guard beats.count > 1, beats.indices.contains(selected) else { return }
        draft.made.beats.remove(at: selected)
        selected = min(selected, beats.count - 1)
    }

    private func copyPose() { copied = beatIfAny }

    /// The copied pose on the picked beat (it keeps its own length).
    private func pastePose() {
        guard var b = copied, beats.indices.contains(selected) else { return }
        b.duration = beats[selected].duration
        draft.made.beats[selected] = b
        replayBeat()
    }

    // MARK: Undo

    /// Keeps the beats as they were before an edit. Quick edits in a row (a slider dragged, an
    /// edge pulled) are one step.
    private func remember(_ old: [AnimationBeat]) {
        if restoring { restoring = false; return }
        let now = Date()
        if now.timeIntervalSince(lastEdit) > 0.6 {
            history.append(old)
            if history.count > 100 { history.removeFirst() }
            future = []
        }
        lastEdit = now
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        future.append(beats)
        restore(last)
    }

    private func redo() {
        guard let next = future.popLast() else { return }
        history.append(beats)
        restore(next)
    }

    private func restore(_ list: [AnimationBeat]) {
        restoring = list != beats
        lastEdit = .distantPast
        draft.made.beats = list
        selected = min(selected, max(0, list.count - 1))
    }

    // MARK: Details

    private var details: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge)
                    StageImp(hue: hue, performance: playing, traits: traits)
                        .frame(width: 150, height: 150)
                }
                .onAppear { playing = performance() }
                .frame(width: 190, height: 180)
                .onTapGesture { playing = performance() }
                .help("Click to play it again")
                Text("\(beats.count) beats · \(Self.seconds(beats.reduce(0) { $0 + $1.duration }))")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Dungeon.muted)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let r = animation.replaces {
                    FieldRow("Plays", width: 64) {
                        Label("Instead of \(r.title)", systemImage: "arrow.triangle.swap")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Dungeon.cream)
                    }
                } else {
                    FieldRow("Name", width: 64) {
                        TextField("What is it called?", text: $draft.made.name).impField()
                    }
                }
                FieldRow("About", width: 64) {
                    TextField("What it looks like, in a few words", text: $draft.made.about).impField()
                }
                FieldRow("For", info: "One made for a single Imp plays only for it, in place of a shared one.", width: 64) {
                    Picker(String(""), selection: $draft.owner) {
                        Text("Every Imp").tag(UUID?.none)
                        ForEach(model.prefs.imps) { imp in Text("\(imp.callName) only").tag(Optional(imp.id)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                FieldRow("Icon", width: 64) { IconPicker(symbol: $draft.made.symbol, extra: animation.replaces?.symbol) }
                if !traits.isPlain {
                    Text("\(actor?.callName ?? "") plays it with its own character: \(traits.summary.lowercased()).")
                        .font(.system(size: 11.5)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
                }
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
        withAnimation(.snappy) { model.prefs.save(a, for: draft.owner) }
        dismiss()
    }
}

// MARK: - Stage

/// The stage: the Imp acting it out, and the place to turn its face. Drag anywhere on it and the
/// face turns there (a dashed line shows where it looks); double-click to have it look at you.
private struct LookStage: View {
    let hue: Double
    let traits: ImpTraits
    let performance: Performance?
    /// The beat being edited (nil while the whole animation plays).
    let beat: AnimationBeat?
    let onLook: (Double, Double) -> Void
    @State private var hovering = false
    @Environment(\.impTint) private var tint

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Where its face is: the look is aimed from there.
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 22)
            let reach = CGSize(width: size.width / 2 - 18, height: size.height / 2 - 18)
            ZStack {
                StageImp(hue: hue, performance: performance, traits: traits)
                    .frame(width: 176, height: 176)
                    .position(x: size.width / 2, y: size.height / 2 + 10)
                    .allowsHitTesting(false)
                if let beat, beat.hasLook || hovering {
                    guide(size: size, center: center, reach: reach, beat: beat)
                }
                if beat != nil, hovering, beat?.hasLook == false {
                    Text("Drag to turn its face").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Dungeon.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                        .position(x: size.width / 2, y: 14)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard beat != nil else { return }
                let x = (g.location.x - center.x) / reach.width, y = (g.location.y - center.y) / reach.height
                onLook(AnimationBeat.round(max(-1, min(1, Double(x)))), AnimationBeat.round(max(-1, min(1, Double(y)))))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if beat != nil { onLook(0, 0.1) } })
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview. Where it looks")
        .accessibilityValue(beat.map { $0.hasLook ? Text(verbatim: String(format: "%.1f, %.1f", $0.lookX ?? 0, $0.lookY ?? 0)) : Text("Follows the cursor") } ?? Text(verbatim: ""))
        .accessibilityAdjustableAction { dir in
            guard let beat else { return }
            onLook(beat.lookX ?? 0, max(-1, min(1, (beat.lookY ?? 0) + (dir == .increment ? -0.1 : 0.1))))
        }
    }

    /// A faint crosshair, where you are (just below the middle), and a dashed line to where it looks.
    private func guide(size: CGSize, center: CGPoint, reach: CGSize, beat: AnimationBeat) -> some View {
        let target = CGPoint(x: center.x + CGFloat(beat.lookX ?? 0) * reach.width, y: center.y + CGFloat(beat.lookY ?? 0) * reach.height)
        let you = CGPoint(x: center.x, y: center.y + 0.1 * reach.height)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: center.x, y: 8)); p.addLine(to: CGPoint(x: center.x, y: size.height - 8))
                p.move(to: CGPoint(x: 8, y: center.y)); p.addLine(to: CGPoint(x: size.width - 8, y: center.y))
            }
            .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            Circle().strokeBorder(Dungeon.muted.opacity(0.7), lineWidth: 1).frame(width: 9, height: 9).position(you)
            if beat.hasLook {
                Path { p in p.move(to: center); p.addLine(to: target) }
                    .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                Circle().fill(tint).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(target)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Timeline

/// The beats in a row, as long as they last, over a ruler in seconds. Click a beat to pick it, drag
/// it to move it, drag its right edge to change its length; click the ruler to play from there.
private struct BeatTrack: View {
    @Binding var beats: [AnimationBeat]
    @Binding var selected: Int
    let hue: Double
    let zoom: CGFloat
    let playing: Performance?
    let tempo: Double
    let copied: Bool
    let onPlay: (Double) -> Void
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onSplit: () -> Void
    let onRemove: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    /// A beat being dragged to a new place.
    struct Move: Equatable { var index: Int; var dx: CGFloat; var target: Int }
    /// A beat's edge being dragged.
    struct Resize: Equatable { var index: Int; var start: Double }
    @State private var moving: Move?
    @State private var resizing: Resize?
    /// How wide the track is, so a short animation fills it.
    @State private var room: CGFloat = 600
    @Environment(\.impTint) private var tint

    static let gap: CGFloat = 3
    static let minTile: CGFloat = 30
    static let tileHeight: CGFloat = 58
    static let rulerHeight: CGFloat = 16
    /// Points per second: the whole animation fits the width at 1×, within reason.
    private var pps: CGFloat {
        let total = max(0.1, beats.reduce(0) { $0 + $1.duration })
        let fit = (room - 44 - Self.gap * CGFloat(beats.count)) / total
        return min(max(fit, 36), 220) * zoom
    }

    private var widths: [CGFloat] { beats.map { max(Self.minTile, $0.duration * pps) } }

    private static func starts(_ widths: [CGFloat]) -> [CGFloat] {
        var x: CGFloat = 0
        return widths.map { w in defer { x += w + gap }; return x }
    }

    var body: some View {
        let ws = widths
        let xs = Self.starts(ws)
        let end = (xs.last ?? 0) + (ws.last ?? 0)
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 3) {
                    ruler(ws: ws, xs: xs, width: end)
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: end + Self.gap + 34, height: Self.tileHeight)
                        ForEach(beats.indices, id: \.self) { i in tile(i, ws: ws, xs: xs) }
                        let addAt = -(end + Self.gap)
                        addTile.alignmentGuide(.leading) { _ in addAt }
                        playhead(ws: ws, xs: xs)
                    }
                    .coordinateSpace(.named("track"))
                }
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selected) { _, i in withAnimation { scroller.scrollTo(i) } }
        }
        .frame(height: Self.rulerHeight + Self.tileHeight + 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    // MARK: Ruler

    /// The track's x for a time in the animation (beats shorter than a tile still get a whole tile).
    private func x(at t: Double, ws: [CGFloat], xs: [CGFloat]) -> CGFloat {
        var left = t
        for (i, b) in beats.enumerated() {
            if left <= b.duration { return xs[i] + ws[i] * CGFloat(left / max(b.duration, 0.001)) }
            left -= b.duration
        }
        return (xs.last ?? 0) + (ws.last ?? 0)
    }

    /// The time at a point on the track.
    private func time(at x: CGFloat, ws: [CGFloat], xs: [CGFloat]) -> Double {
        var t = 0.0
        for (i, b) in beats.enumerated() {
            if x < xs[i] + ws[i] + Self.gap { return t + b.duration * Double(max(0, min(1, (x - xs[i]) / ws[i]))) }
            t += b.duration
        }
        return t
    }

    private func ruler(ws: [CGFloat], xs: [CGFloat], width: CGFloat) -> some View {
        let total = beats.reduce(0) { $0 + $1.duration }
        let step = pps < 50 ? 0.5 : pps > 140 ? 0.1 : 0.25
        return Canvas { ctx, size in
            var t = 0.0
            while t <= total + 0.0001 {
                let px = x(at: t, ws: ws, xs: xs)
                let whole = abs(t.rounded() - t) < 0.001
                let h: CGFloat = whole ? 7 : 4
                ctx.fill(Path(CGRect(x: px, y: size.height - h, width: 1, height: h)), with: .color(Dungeon.muted.opacity(whole ? 0.8 : 0.4)))
                if whole {
                    ctx.draw(Text(verbatim: "\(Int(t.rounded())) s").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Dungeon.muted),
                             at: CGPoint(x: px + 3, y: 1), anchor: .topLeading)
                }
                t += step
            }
        }
        .frame(width: width + 34, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .onTapGesture { p in onPlay(time(at: p.x, ws: ws, xs: xs)) }
        .help("Click to play from there")
        .accessibilityElement()
        .accessibilityLabel("Ruler")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPlay(0) }
    }

    @ViewBuilder private func playhead(ws: [CGFloat], xs: [CGFloat]) -> some View {
        if let playing {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSince(playing.started) * tempo
                Capsule().fill(Color.white).frame(width: 2, height: Self.tileHeight + 6)
                    .shadow(color: tint, radius: 3)
                    .offset(x: x(at: t, ws: ws, xs: xs) - 1, y: -3)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Beats

    /// Where beat `i` sits: while another is dragged, the others make room where it would land.
    private func place(_ i: Int, ws: [CGFloat], xs: [CGFloat]) -> CGFloat {
        guard let m = moving else { return xs[i] }
        if i == m.index { return xs[i] + m.dx }
        var order = Array(beats.indices)
        order.remove(at: m.index)
        order.insert(m.index, at: m.target)
        var x: CGFloat = 0
        for j in order {
            if j == i { return x }
            x += ws[j] + Self.gap
        }
        return xs[i]
    }

    private func tile(_ i: Int, ws: [CGFloat], xs: [CGFloat]) -> some View {
        let dragged = moving?.index == i
        let x = place(i, ws: ws, xs: xs)
        return BeatTile(beat: beats[i], index: i, picked: i == selected, hue: hue, width: ws[i],
                        resizing: resizing?.index == i)
            .overlay(alignment: .trailing) { edge(i) }
            .scaleEffect(dragged ? 1.04 : 1)
            .shadow(color: .black.opacity(dragged ? 0.45 : 0), radius: 6, y: 2)
            .zIndex(dragged ? 2 : 0)
            .alignmentGuide(.leading) { _ in -x }
            .animation(dragged ? nil : .snappy(duration: 0.2), value: moving?.target)
            .id(i)
            .onTapGesture { withAnimation(.snappy(duration: 0.15)) { selected = i } }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("track"))
                .onChanged { g in
                    if moving == nil { selected = i }
                    let center = xs[i] + ws[i] / 2 + g.translation.width
                    let target = beats.indices.filter { $0 != i && xs[$0] + ws[$0] / 2 < center }.count
                    moving = Move(index: i, dx: g.translation.width, target: target)
                }
                .onEnded { _ in
                    guard let m = moving else { return }
                    moving = nil
                    guard m.target != m.index else { return }
                    let b = beats.remove(at: m.index)
                    beats.insert(b, at: m.target)
                    selected = m.target
                })
            .contextMenu {
                Button("Duplicate") { selected = i; onDuplicate() }
                Button("Split in Two") { selected = i; onSplit() }
                Button("Add a Beat After") { selected = i; onAdd() }
                Divider()
                Button("Copy Pose") { selected = i; onCopy() }
                Button("Paste Pose") { selected = i; onPaste() }.disabled(!copied)
                Divider()
                Button("Remove", role: .destructive) { selected = i; onRemove() }.disabled(beats.count <= 1)
            }
    }

    /// The right edge of a beat: drag it to change how long the beat lasts.
    private func edge(_ i: Int) -> some View {
        EdgeHandle(active: resizing?.index == i || i == selected)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("track"))
                .onChanged { g in
                    guard beats.indices.contains(i) else { return }
                    if resizing == nil { resizing = Resize(index: i, start: beats[i].duration); selected = i }
                    let fine = NSEvent.modifierFlags.contains(.option)
                    let step = fine ? 0.01 : 0.05
                    let raw = (resizing?.start ?? beats[i].duration) + Double(g.translation.width / pps)
                    let d = min(max((raw / step).rounded() * step, AnimationBeat.durationRange.lowerBound), AnimationBeat.durationRange.upperBound)
                    if abs(beats[i].duration - d) > 0.0001 { beats[i].duration = AnimationBeat.round(d) }
                }
                .onEnded { _ in resizing = nil })
    }

    private var addTile: some View {
        Button(action: onAdd) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Dungeon.muted)
                .frame(width: 30, height: Self.tileHeight)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Dungeon.cardEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(beats.count >= MadeAnimation.maxBeats)
        .help("Add a beat after this one")
    }
}

/// The grip on a beat's right edge.
private struct EdgeHandle: View {
    let active: Bool
    @State private var hover = false
    @Environment(\.impTint) private var tint

    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(width: 9)
            .overlay {
                Capsule().fill(hover ? Color.white : (active ? tint : Color.white.opacity(0.25)))
                    .frame(width: 3, height: 22)
                    .opacity(hover || active ? 1 : 0.6)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help("Drag to make the beat longer or shorter (⌥ for finer steps)")
            .accessibilityHidden(true)
    }
}

/// One beat on the timeline: its face, its move, symbol and hop if it has them, and how long it holds.
private struct BeatTile: View {
    let beat: AnimationBeat
    let index: Int
    let picked: Bool
    let hue: Double
    let width: CGFloat
    var resizing = false
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Text(verbatim: "\(index + 1)").font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(picked ? Color.white.opacity(0.85) : Dungeon.muted.opacity(0.8))
                Spacer(minLength: 0)
                if width >= 44 {
                    if let m = beat.move { Image(systemName: MovePicker.symbol(m)).font(.system(size: 8, weight: .bold)) }
                    if beat.hop { Image(systemName: "arrow.up").font(.system(size: 8, weight: .black)) }
                    if let g = beat.glyph { Image(systemName: GlyphPicker.symbol(g)).font(.system(size: 8, weight: .bold)) }
                }
            }
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 5).padding(.top, 3)
            .frame(height: 13)
            ImpPortrait(face: face, shadow: false).frame(width: min(28, width - 6), height: 26)
            Text(verbatim: width >= 40 ? String(format: "%.2g s", beat.duration) : String(format: "%.1f", beat.duration))
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(picked || resizing ? Color.white : Dungeon.muted)
                .lineLimit(1)
        }
        .frame(width: width, height: BeatTrack.tileHeight)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(0.05))))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(picked ? tint : Dungeon.cardEdge, lineWidth: picked ? 1.5 : 1))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("Beat \(index + 1)"))
        .accessibilityValue(Text(verbatim: [beat.mood.flatMap(Mood.init(rawValue:))?.title, beat.move.map(MovePicker.title),
                                            String(format: "%.2f s", beat.duration)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var face: Face {
        var f = Face.settled(beat.mood.flatMap(Mood.init(rawValue:)) ?? .idle, lookX: beat.lookX ?? 0, lookY: beat.lookY ?? 0)
        f.hue = hue
        f.tilt += beat.tilt
        f.headH *= 1 + beat.stretch
        f.headW *= 1 - beat.stretch * 0.6
        return f
    }
}

// MARK: - Pickers

/// Every mood as a little face to pick from.
private struct MoodPicker: View {
    @Binding var mood: String?
    let hue: Double
    @Environment(\.impTint) private var tint

    var body: some View {
        EvenGrid(minWidth: 27, spacing: 3) {
            tile(nil)
            ForEach(AnimationBeat.moods, id: \.self) { tile($0) }
        }
    }

    private func tile(_ name: String?) -> some View {
        let picked = mood == name
        let m = name.flatMap(Mood.init(rawValue:))
        return Button { mood = name } label: {
            ZStack {
                if let m {
                    ImpPortrait(face: { var f = Face.settled(m); f.hue = hue; return f }(), shadow: false).padding(2)
                } else {
                    Image(systemName: "circle.dashed").font(.system(size: 13, weight: .medium)).foregroundStyle(Dungeon.muted)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(0.3)) : AnyShapeStyle(Color.white.opacity(0.04))))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(picked ? tint : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m?.title ?? String(localized: "Keep: whatever it feels anyway"))
        .accessibilityLabel(m?.title ?? String(localized: "Keep its mood"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The moves a beat can play across its length, how many times, and which way.
private struct MovePicker: View {
    @Binding var beat: AnimationBeat
    let replay: () -> Void
    @Environment(\.impTint) private var tint

    static func symbol(_ m: String) -> String {
        switch m {
        case "spin": "rotate.3d"
        case "flip": "figure.gymnastics"
        case "roll": "arrow.clockwise"
        case "bounce": "arrow.up.and.down"
        case "shake": "arrow.left.and.right"
        case "sway": "metronome.fill"
        case "wobble": "waveform.path"
        case "float": "cloud.fill"
        case "nod": "checkmark"
        case "headshake": "xmark"
        default: "circle"
        }
    }

    static func title(_ m: String) -> String {
        switch m {
        case "spin": String(localized: "Spin round its own axis")
        case "flip": String(localized: "Somersault")
        case "roll": String(localized: "Cartwheel")
        case "bounce": String(localized: "Bounce")
        case "shake": String(localized: "Shake")
        case "sway": String(localized: "Sway")
        case "wobble": String(localized: "Wobble like jelly")
        case "float": String(localized: "Float up")
        case "nod": String(localized: "Nod")
        case "headshake": String(localized: "Shake its head")
        default: m
        }
    }

    /// What one "time" is for this move.
    static func unit(_ m: String, _ n: Int) -> String {
        switch m {
        case "spin", "flip", "roll": String(localized: "\(n) turns")
        case "bounce": String(localized: "\(n) bounces")
        case "nod": String(localized: "\(n) nods")
        default: String(localized: "\(n) times")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                chip(nil)
                ForEach(AnimationBeat.moves, id: \.self) { chip($0) }
            }
            if let m = beat.move {
                HStack(spacing: 8) {
                    Text(verbatim: Self.title(m)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Dungeon.cream).lineLimit(1)
                    Spacer(minLength: 4)
                    Stepper(value: Binding(get: { beat.repeats }, set: { beat.times = $0; replay() }), in: AnimationBeat.timesRange) {
                        Text(verbatim: Self.unit(m, beat.repeats)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Dungeon.muted)
                    }
                    .controlSize(.small)
                    .help("How many times it goes")
                    Toggle(isOn: Binding(get: { beat.reverse == true }, set: { beat.reverse = $0 ? true : nil; replay() })) {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .toggleStyle(.button).controlSize(.small)
                    .help("The other way round")
                }
            }
        }
    }

    private func chip(_ m: String?) -> some View {
        let picked = beat.move == m
        return Button {
            beat.move = m
            beat.times = nil
            beat.reverse = nil
            // A move needs time to read: a spin in a flash looks like a glitch.
            if m != nil, beat.duration < 0.6 { beat.duration = 0.8 }
            replay()
        } label: {
            Image(systemName: m.map(Self.symbol) ?? "nosign")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.8))
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.map { Text(verbatim: Self.title($0)) } ?? Text("No move: it holds still"))
        .accessibilityLabel(m.map { Text(verbatim: Self.title($0)) } ?? Text("No move"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The symbols a beat can pop above its head.
private struct GlyphPicker: View {
    @Binding var glyph: String?
    @Environment(\.impTint) private var tint

    static func symbol(_ g: String) -> String {
        switch g {
        case "notes": "music.note"
        case "question": "questionmark"
        case "exclaim": "exclamationmark"
        case "idea": "lightbulb.fill"
        case "sweat": "drop.fill"
        case "heart": "heart.fill"
        case "sparkles": "sparkles"
        default: "circle"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            chip(nil)
            ForEach(AnimationBeat.glyphs, id: \.self) { chip($0) }
        }
    }

    private func chip(_ g: String?) -> some View {
        let picked = glyph == g
        return Button { glyph = g } label: {
            Image(systemName: g.map(Self.symbol) ?? "nosign")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.8))
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityLabel(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The icon for the list, from a grid.
private struct IconPicker: View {
    @Binding var symbol: String
    let extra: String?
    @Environment(\.impTint) private var tint

    var body: some View {
        EvenGrid(minWidth: 30, spacing: 4) {
            ForEach((extra.map { [$0] } ?? []) + MadeAnimation.symbols.filter { $0 != extra }, id: \.self) { s in
                Button { symbol = s } label: {
                    Image(systemName: s).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(symbol == s ? Color.white : Dungeon.cream.opacity(0.8))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(symbol == s ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: s))
                .accessibilityLabel(Text(verbatim: s))
                .accessibilityAddTraits(symbol == s ? .isSelected : [])
            }
        }
    }
}

/// A slider and its value, for a tight row. Double-click puts it back to 0.
private struct CompactSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $value, in: range)
            Text(verbatim: format(value)).font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .onTapGesture(count: 2) { value = min(max(0, range.lowerBound), range.upperBound) }
    }
}

/// A slider with words at both ends and its value.
struct LabeledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let left: LocalizedStringKey
    let right: LocalizedStringKey
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(left).font(.system(size: 11)).foregroundStyle(Dungeon.muted).lineLimit(1)
            Slider(value: $value, in: range)
            Text(right).font(.system(size: 11)).foregroundStyle(Dungeon.muted).lineLimit(1)
            Text(verbatim: format(value)).font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .onTapGesture(count: 2) { value = min(max(0, range.lowerBound), range.upperBound) }
    }
}

extension Mood {
    /// Its name, for people.
    var title: String {
        switch self {
        case .idle: String(localized: "Calm")
        case .listening: String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .happy: String(localized: "Happy")
        case .love: String(localized: "In love")
        case .sad: String(localized: "Sad")
        case .error: String(localized: "Wincing")
        case .sleepy: String(localized: "Sleepy")
        case .annoyed: String(localized: "Annoyed")
        case .surprised: String(localized: "Surprised")
        case .dizzy: String(localized: "Dizzy")
        case .mean: String(localized: "Unimpressed")
        case .working: String(localized: "Busy")
        case .content: String(localized: "Content")
        case .giggly: String(localized: "Giggly")
        case .scared: String(localized: "Scared")
        case .curious: String(localized: "Curious")
        case .shy: String(localized: "Shy")
        case .excited: String(localized: "Excited")
        case .bored: String(localized: "Bored")
        }
    }
}
