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

/// The animation editor: a stage that acts it out, a timeline of beats, and the pose of the beat
/// picked on it. Every built-in animation opens here too (as a new version of itself), so nothing
/// is simplified on the way in: what you see is exactly what it plays.
struct AnimationEditor: View {
    let model: AppModel
    @State private var draft: AnimationDraft
    @State private var selected = 0
    @State private var playing: Performance?
    @State private var loops = false
    /// When the beat on the stage started holding (a new pick shows its hop once).
    @State private var holdStarted = Date()
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, draft: AnimationDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    private var animation: MadeAnimation { draft.made }
    private var beats: [AnimationBeat] { draft.made.beats }
    private var actor: ImpProfile? { (draft.owner ?? draft.previewImp).flatMap(model.profile) ?? model.prefs.imps.first }
    private var hue: Double { actor?.hue ?? 0 }
    private var traits: ImpTraits { actor?.traits ?? .plain }
    private var tint: Color { Color.imp(hue) }

    var body: some View {
        SheetScaffold(icon: animation.symbol, title: title, info: "Beats play one after another. Each holds a pose: a mood, where the face turns, a tilt, a shape, a symbol, a hop.", width: 660) {
            ShareKitButton(kit: Kit(name: animation.title, animations: [animation.normalized]), help: "Share this animation as a kit")
        } content: {
            HStack(alignment: .top, spacing: 16) {
                stage
                details
            }
            timeline
            inspector
        } footer: {
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
            Button("Save") { save() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(beats.isEmpty || (animation.replaces == nil && animation.name.trimmingCharacters(in: .whitespaces).isEmpty))
        }
        .environment(\.impTint, tint)
        .tint(tint)
        .onChange(of: selected) { holdStarted = Date() }
    }

    private var title: LocalizedStringKey {
        if let r = animation.replaces { return draft.isNew ? "Your own \(r.title)" : "Change \(r.title)" }
        return draft.isNew ? "New Animation" : "Change \(animation.title)"
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.black.opacity(0.22))
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge)
                StageImp(hue: hue, performance: playing ?? holding, traits: traits)
                    .frame(width: 150, height: 150)
                    .offset(y: 4)
                    .task(id: playing?.started) {
                        guard let p = playing else { return }
                        try? await Task.sleep(for: .seconds(p.duration + 0.35))
                        guard playing == p else { return }
                        playing = loops ? performance() : nil
                    }
            }
            .frame(width: 180, height: 170)
            .accessibilityLabel("Preview")
            HStack(spacing: 6) {
                Button { playing = playing == nil ? performance() : nil } label: {
                    Label(playing == nil ? "Play" : "Stop", systemImage: playing == nil ? "play.fill" : "stop.fill")
                }
                .buttonStyle(.imp(.secondary, small: true))
                .keyboardShortcut(.space, modifiers: [])
                .help("Play it from the start (Space)")
                Toggle(isOn: $loops) { Image(systemName: "repeat") }
                    .toggleStyle(.button).controlSize(.small)
                    .help("Play it again and again")
                Text(verbatim: Self.seconds(Antics.paced(beats.map(AnticStep.init), tempo: traits.tempo).reduce(0) { $0 + $1.duration }))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Dungeon.muted)
                    .help("How long it plays (at \(actor?.callName ?? "the Imp")'s own pace)")
            }
        }
    }

    /// The whole animation, at the pace of the Imp acting it out.
    private func performance() -> Performance {
        Performance(key: "draft", steps: Antics.paced(beats.map(AnticStep.init), tempo: traits.tempo))
    }

    /// The picked beat, held on the stage.
    private var holding: Performance? {
        guard beats.indices.contains(selected) else { return nil }
        var step = AnticStep(beats[selected])
        step.duration = 3600
        return Performance(key: "hold", steps: [step], at: holdStarted)
    }

    // MARK: Name and owner

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            FieldRow("Icon", width: 64) {
                Menu {
                    ForEach(MadeAnimation.symbols + (animation.replaces.map { [$0.symbol] } ?? []), id: \.self) { s in
                        Button { draft.made.symbol = s } label: { Label(s, systemImage: s) }
                    }
                } label: {
                    Image(systemName: animation.symbol).font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("The icon in the list")
            }
            FieldRow("For", info: "One made for a single Imp plays only for it, in place of a shared one.", width: 64) {
                Picker(String(""), selection: $draft.owner) {
                    Text("Every Imp").tag(UUID?.none)
                    ForEach(model.prefs.imps) { imp in Text("\(imp.callName) only").tag(Optional(imp.id)) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if !traits.isPlain {
                Text("\(actor?.callName ?? "") plays it with its own character: \(traits.summary.lowercased()).")
                    .font(.system(size: 11.5)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Timeline

    private static let pointsPerSecond: CGFloat = 70
    private static func width(_ b: AnimationBeat) -> CGFloat { max(46, b.duration * pointsPerSecond) }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Beats").font(.system(size: 13, weight: .bold, design: .rounded))
                Text(verbatim: "\(beats.count)/\(MadeAnimation.maxBeats)").font(.system(size: 11, weight: .medium)).foregroundStyle(Dungeon.muted)
                Spacer()
                HoverIconButton(systemName: "arrow.left", help: "Move the beat earlier") { move(-1) }.disabled(selected <= 0)
                HoverIconButton(systemName: "arrow.right", help: "Move the beat later") { move(1) }.disabled(selected >= beats.count - 1)
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate the beat") { duplicate() }
                    .disabled(beats.count >= MadeAnimation.maxBeats || beats.isEmpty)
                HoverIconButton(systemName: "trash", help: "Remove the beat") { remove() }.disabled(beats.count <= 1)
                Button { add() } label: { Label("Beat", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(beats.count >= MadeAnimation.maxBeats)
                    .help("Add a beat after this one")
            }
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(beats.enumerated()), id: \.offset) { i, beat in
                            BeatTile(beat: beat, index: i, picked: i == selected, hue: hue, width: Self.width(beat))
                                .id(i)
                                .onTapGesture { withAnimation(.snappy(duration: 0.15)) { selected = i } }
                        }
                    }
                    .padding(.vertical, 2)
                    .overlay(alignment: .topLeading) { playhead }
                }
                .scrollIndicators(.automatic)
                .onChange(of: selected) { _, i in withAnimation { scroller.scrollTo(i) } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }

    /// Where the animation is while it plays: a line moving over the beats.
    @ViewBuilder private var playhead: some View {
        if let playing {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let x = Self.playheadX(at: tl.date.timeIntervalSince(playing.started) * traits.tempo, beats: beats)
                Capsule().fill(Color.white).frame(width: 2, height: 64).offset(x: x).shadow(color: tint, radius: 3)
            }
            .allowsHitTesting(false)
        }
    }

    private static func playheadX(at t: Double, beats: [AnimationBeat]) -> CGFloat {
        var left = t, x: CGFloat = 0
        for b in beats {
            let w = width(b)
            if left < b.duration { return x + w * left / b.duration }
            left -= b.duration
            x += w + 4
        }
        return max(0, x - 4)
    }

    private func add() {
        var b = beats.indices.contains(selected) ? beats[selected] : AnimationBeat(duration: 0.5)
        b.hop = false
        b.glyph = nil
        let at = min(selected + 1, beats.count)
        draft.made.beats.insert(b, at: at)
        selected = at
    }

    private func duplicate() {
        guard beats.indices.contains(selected) else { return }
        draft.made.beats.insert(beats[selected], at: selected + 1)
        selected += 1
    }

    private func remove() {
        guard beats.count > 1, beats.indices.contains(selected) else { return }
        draft.made.beats.remove(at: selected)
        selected = min(selected, beats.count - 1)
    }

    private func move(_ by: Int) {
        let to = selected + by
        guard beats.indices.contains(selected), beats.indices.contains(to) else { return }
        draft.made.beats.swapAt(selected, to)
        selected = to
    }

    // MARK: The picked beat

    private var beat: Binding<AnimationBeat> {
        Binding(get: { beats.indices.contains(selected) ? beats[selected] : AnimationBeat(duration: 0.5) },
                set: { if draft.made.beats.indices.contains(selected) { draft.made.beats[selected] = $0 } })
    }

    @ViewBuilder private var inspector: some View {
        if beats.indices.contains(selected) {
            Card("Beat \(selected + 1)", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    FieldRow("Length", width: 64) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { beat.wrappedValue.duration }, set: { beat.wrappedValue.duration = max(0.05, ($0 * 20).rounded() / 20) }), in: 0.05...4)
                            Text(verbatim: Self.seconds(beat.wrappedValue.duration))
                                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    FieldRow("Mood", info: "How it feels during this beat. Keep: whatever it feels anyway.", width: 64) {
                        MoodPicker(mood: beat.mood, hue: hue)
                    }
                    FieldRow("Look", info: "Drag to turn its face. The dot in the middle is you. Off: it follows the cursor (or its mood decides).", width: 64) {
                        HStack(alignment: .top, spacing: 14) {
                            LookPad(lookX: beat.lookX, lookY: beat.lookY)
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Turns its face", isOn: Binding(
                                    get: { beat.wrappedValue.hasLook },
                                    set: { on in
                                        beat.wrappedValue.lookX = on ? 0 : nil
                                        beat.wrappedValue.lookY = on ? 0.1 : nil
                                    }))
                                    .toggleStyle(.switch).controlSize(.small)
                                Toggle("Hops", isOn: Binding(get: { beat.wrappedValue.hop },
                                                             set: { beat.wrappedValue.hop = $0; if $0 { holdStarted = Date() } }))
                                    .toggleStyle(.switch).controlSize(.small)
                                    .help("A hop as the beat starts (it takes 0.75 s)")
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                    FieldRow("Symbol", width: 64) {
                        GlyphPicker(glyph: beat.glyph)
                    }
                    FieldRow("Tilt", width: 64) {
                        LabeledSlider(value: beat.tilt, range: AnimationBeat.tiltRange, left: "Left", right: "Right", format: { "\(Int($0.rounded()))°" })
                    }
                    FieldRow("Shape", width: 64) {
                        LabeledSlider(value: beat.stretch, range: AnimationBeat.stretchRange, left: "Squish", right: "Tall",
                                      format: { String(format: "%+.2f", $0) })
                    }
                }
            }
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

/// One beat on the timeline: its face, a symbol and a hop if it has them, and how long it holds.
private struct BeatTile: View {
    let beat: AnimationBeat
    let index: Int
    let picked: Bool
    let hue: Double
    let width: CGFloat
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                ImpPortrait(face: face, shadow: false).frame(width: 34, height: 34)
                HStack(spacing: 1) {
                    if beat.hop { Image(systemName: "arrow.up").font(.system(size: 8, weight: .black)) }
                    if let g = beat.glyph { Image(systemName: GlyphPicker.symbol(g)).font(.system(size: 8, weight: .bold)) }
                }
                .foregroundStyle(Dungeon.cream)
                .offset(x: 6, y: -2)
            }
            Text(verbatim: String(format: "%.2g s", beat.duration))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(picked ? Color.white : Dungeon.muted)
        }
        .frame(width: width, height: 62)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(0.05))))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(picked ? tint : Dungeon.cardEdge, lineWidth: picked ? 1.5 : 1))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("Beat \(index + 1)"))
        .accessibilityValue(Text(verbatim: [beat.mood.flatMap(Mood.init(rawValue:))?.title, String(format: "%.2f s", beat.duration)].compactMap { $0 }.joined(separator: ", ")))
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

/// Every mood as a little face to pick from.
private struct MoodPicker: View {
    @Binding var mood: String?
    let hue: Double
    @Environment(\.impTint) private var tint

    var body: some View {
        EvenGrid(minWidth: 36, spacing: 4) {
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
                    Image(systemName: "circle.dashed").font(.system(size: 16, weight: .medium)).foregroundStyle(Dungeon.muted)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(0.3)) : AnyShapeStyle(Color.white.opacity(0.04))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(picked ? tint : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m?.title ?? String(localized: "Keep: whatever it feels anyway"))
        .accessibilityLabel(m?.title ?? String(localized: "Keep its mood"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A square to drag where the face turns: up and down, left and right.
private struct LookPad: View {
    @Binding var lookX: Double?
    @Binding var lookY: Double?
    @Environment(\.impTint) private var tint
    private let size = CGSize(width: 132, height: 92)

    var body: some View {
        let on = lookX != nil || lookY != nil
        let p = CGPoint(x: (CGFloat(lookX ?? 0) + 1) / 2 * size.width, y: (CGFloat(lookY ?? 0) + 1) / 2 * size.height)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
            Path { path in
                path.move(to: CGPoint(x: size.width / 2, y: 6)); path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 6))
                path.move(to: CGPoint(x: 6, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
            }
            .stroke(Dungeon.cardEdge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // You: just below the middle, where an Imp looks to look at you.
            Circle().strokeBorder(Dungeon.muted, lineWidth: 1).frame(width: 8, height: 8)
                .position(x: size.width / 2, y: (0.1 + 1) / 2 * size.height)
            if on {
                Circle().fill(tint).frame(width: 14, height: 14).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 2).position(p)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            lookX = AnimationBeat.round(max(-1, min(1, Double(g.location.x / size.width) * 2 - 1)))
            lookY = AnimationBeat.round(max(-1, min(1, Double(g.location.y / size.height) * 2 - 1)))
        })
        .opacity(on ? 1 : 0.6)
        .help("Drag to turn its face")
        .accessibilityElement()
        .accessibilityLabel("Where it looks")
        .accessibilityValue(on ? Text(verbatim: String(format: "%.1f, %.1f", lookX ?? 0, lookY ?? 0)) : Text("Follows the cursor"))
        .accessibilityAdjustableAction { dir in
            let y = lookY ?? 0
            lookY = max(-1, min(1, y + (dir == .increment ? -0.1 : 0.1)))
            if lookX == nil { lookX = 0 }
        }
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
        HStack(spacing: 4) {
            chip(nil)
            ForEach(AnimationBeat.glyphs, id: \.self) { chip($0) }
        }
    }

    private func chip(_ g: String?) -> some View {
        let picked = glyph == g
        return Button { glyph = g } label: {
            Image(systemName: g.map(Self.symbol) ?? "nosign")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.8))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityLabel(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityAddTraits(picked ? .isSelected : [])
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
