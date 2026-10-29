import AppKit
import ImpKit
import SwiftUI

/// The home screen: one Imp in the doorway, its name above, its colour and a row of actions
/// below (settings, let it out or call it home, more). Arrows (or ← →, or a swipe)
/// visit the others, who wait at either side watching. The egg at the end hatches a new one.
/// Click a resting Imp to open its settings. New Imps (hatched here, imported, or from a link)
/// come out of the egg one after another (see `HomeRouter.hatch`).
struct ImpStage: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    @State private var drag: CGFloat = 0
    /// The Imp that just stepped out of its egg (it's happy about it for a moment).
    @State private var hatched: UUID?
    /// When the egg started cracking open (nil = resting), and how fast.
    @State private var hatchStart: Date?
    @State private var hatchPace: Double = 1
    /// The egg waiting at the end of the line. Gone while an Imp steps out of it, then it grows back.
    @State private var eggShown = true
    @State private var eggArriving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleting: UUID?
    @State private var pickingShade = false
    @FocusState private var stageFocused: Bool

    /// How far apart the Imps stand: 250 pt, closer in a narrow window so the ones at the sides
    /// stay clear of the arrows.
    static func spacing(width: CGFloat) -> CGFloat { min(250, max(170, width / 2 - 125)) }
    /// One position on the stage (pedestal and Imp, or the egg), standing on the floor.
    static let pageSize = CGSize(width: 220, height: 224)
    /// The floor line (the pedestal's bottom), up from the stage's bottom edge.
    static let floorInset: CGFloat = 30
    /// The big button's label width, whatever it says.
    static let actionWidth: CGFloat = 200
    /// The Imps either side are smaller and dimmer, waiting their turn.
    static let neighbourScale: CGFloat = 0.62
    /// How far a drag has to be (or look like it's heading) to count as a flick to the next Imp.
    static let flickDistance: CGFloat = 90
    /// The page follows the finger by this much, and by much less past either end.
    static let followRatio: CGFloat = 0.8
    static let edgeResistance: CGFloat = 0.3
    /// Most dots shown at once. With more Imps the row scrolls along, the ends shrinking.
    static let maxDots = 9
    /// Most eggs cracked one by one for a batch. The rest just join the line.
    static let maxEggs = 6
    /// Pauses in the hatch sequence, in seconds: after the stage slides to an egg, after a new egg
    /// has grown in, and how long the new Imp stays pleased.
    private static let settle = 0.35
    private static let beat = 0.3
    private static let linger = 1.2
    private static let badge: CGFloat = 9

    /// The line of pages (Imps already out of their eggs, then the egg) and where the stage is in it.
    /// Worked out once per body and handed down.
    private struct Line {
        let pages: [UUID?]
        let index: Int
    }

    private var line: Line {
        let waiting = router.unhatched
        let imps = model.prefs.imps.map(\.id)
        let pages: [UUID?] = (waiting.isEmpty ? imps : imps.filter { !waiting.contains($0) }) + (eggShown ? [nil] : [])
        return Line(pages: pages, index: pages.firstIndex(of: router.selection) ?? 0)
    }

    /// An egg is cracking or about to: the line stays put until it's done.
    private var busy: Bool { hatchStart != nil || !router.unhatched.isEmpty }
    private var glide: Animation? { reduceMotion ? nil : .snappy(duration: 0.32) }
    private var current: ImpProfile? { router.selection.flatMap(model.profile) }

    /// Where the selected Imp is drawn, in the stage's coordinates (top-left origin). The stage
    /// lays it out with these numbers, and `HomeRouter.slot` turns them into screen coordinates.
    static func figureRect(stage: CGSize, side: CGFloat) -> CGRect {
        let floor = stage.height - floorInset
        // The head's base sits on the stone's top. The canvas keeps 16% below the base for the shadow.
        let bottom = floor - Pedestal.surface + side * 0.16
        return CGRect(x: stage.width / 2 - side / 2, y: bottom - side, width: side, height: side)
    }

    var body: some View {
        let line = line
        VStack(spacing: 0) {
            topBar
            header
            Spacer(minLength: 6)
            stage(line)
            Spacer(minLength: 10)
            controls
                .padding(.bottom, 12)
            dots(line)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.impTint, Color.imp(current?.hue ?? 0.08))
        .focusable()
        .focusEffectDisabled()
        .focused($stageFocused)
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in step(-1); return .handled }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in step(1); return .handled }
        .onKeyPress(.home) { step(-line.pages.count); return .handled }
        .onKeyPress(.end) { step(line.pages.count); return .handled }
        .onKeyPress(.return) {
            if let imp = current { toggleActive(imp.id) } else { hatch() }
            return .handled
        }
        .onAppear { stageFocused = true }
        // Plays the eggs that are waiting, and again whenever another is added. Leaving the stage
        // stops it; what hasn't hatched yet waits in the router for the way back.
        .task(id: router.hatchRequests) { await playHatches() }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Say Goodbye", role: .destructive) {
                if let id = deleting { remove(id) }
            }
        } message: {
            Text("Its looks, brain, tools, triggers and chats go with it. This can't be undone.")
        }
    }

    // MARK: Top

    /// The title bar row, level with the traffic lights (empty: the gear sits by Let Imp Out).
    private var topBar: some View {
        TopBar { EmptyView() }
    }

    /// Settings every Imp shares, to the right of the big button (this Imp's own are on its left).
    private var generalSettingsButton: some View {
        Button { withAnimation(.snappy(duration: 0.28)) { router.screen = .general } } label: {
            RoundGlyph(systemName: "gearshape.fill", size: 40)
        }
        .buttonStyle(.plain)
        .help("Open the settings every Imp shares (⌘,)")
        .accessibilityLabel("Settings for all Imps")
    }

    /// Just the name (click to rename), at a fixed height: nothing above the stage ever grows or
    /// shrinks, so letting an Imp out, hiding or hatching never nudges the layout.
    @ViewBuilder private var header: some View {
        Group {
            if let imp = current {
                NameField(name: Binding(get: { imp.name }, set: { rename(imp.id, $0) }),
                          editing: $router.renaming, others: model.prefs.imps.filter { $0.id != imp.id }.map(\.name))
            } else {
                Text("A new Imp?")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Dungeon.cream)
                    .help("Every Imp hatches with a brain to chat and a shell to get things done. It waits here until you let it out.")
            }
        }
        .frame(height: 44)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Stage

    private func stage(_ line: Line) -> some View {
        GeometryReader { geo in
            let floor = geo.size.height - Self.floorInset
            let doorHeight = min(geo.size.height - 10, 330)
            let figureMid = Self.figureRect(stage: geo.size, side: Panels.baseSize).midY
            let spacing = Self.spacing(width: geo.size.width)
            ZStack {
                Doorway()
                    .frame(width: 300 + 2 * Doorway.torchRoom, height: doorHeight)
                    .position(x: geo.size.width / 2, y: floor - doorHeight / 2 + 12)
                ForEach(Array(line.pages.enumerated()), id: \.element) { i, id in
                    let d = i - line.index
                    if abs(d) <= 1 {
                        // How far from the middle it is right now, fractions while a finger drags.
                        page(id, offset: d, focus: abs(CGFloat(d) + drag / spacing))
                            .position(x: geo.size.width / 2 + CGFloat(d) * spacing + drag,
                                      y: floor - Self.pageSize.height / 2)
                            .zIndex(d == 0 ? 1 : 0)
                            .transition(.identity)
                    }
                }
                arrow(left: true, line).position(x: 36, y: figureMid)
                arrow(left: false, line).position(x: geo.size.width - 36, y: figureMid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { follow($0.translation.width, spacing: spacing, line) }
                .onEnded { v in
                    let ahead = v.predictedEndTranslation.width
                    withAnimation(glide) { drag = 0 }
                    if ahead < -Self.flickDistance { step(1) } else if ahead > Self.flickDistance { step(-1) }
                })
            // Two fingers on the trackpad flick between Imps, the page following them.
            .onTrackpadSwipe { swipe in
                switch swipe {
                case .follow(let x): follow(x, spacing: spacing, line)
                case .commit(let pages):
                    withAnimation(glide) { drag = 0 }
                    step(pages)
                case .cancel: withAnimation(glide) { drag = 0 }
                }
            }
        }
        // The stage's place on screen, for the selected Imp's slot (see `HomeRouter.slot`).
        .background(StageAnchor(router: router))
        .frame(minHeight: 250, maxHeight: 330)
    }

    /// The page follows a drag, but never further than the next Imp, and it resists at either end.
    private func follow(_ x: CGFloat, spacing: CGFloat, _ line: Line) {
        guard !busy else { return }
        let atEnd = (x > 0 && line.index == 0) || (x < 0 && line.index == line.pages.count - 1)
        drag = min(max(x * Self.followRatio * (atEnd ? Self.edgeResistance : 1), -spacing), spacing)
    }

    /// One position on the stage: an Imp standing on its pedestal, or the egg. `offset` is how
    /// many places from the middle it is (0 = the selected one), `focus` how far in between.
    @ViewBuilder private func page(_ id: UUID?, offset: Int, focus: CGFloat) -> some View {
        let imp = id.flatMap(model.profile)
        let isCurrent = offset == 0
        ZStack(alignment: .bottom) {
            Pedestal(hue: imp?.hue ?? 0.08, lit: isCurrent && (imp?.isActive != true || model.isHidden))
                .frame(width: 170)
            if let imp {
                impFigure(imp, offset: offset)
                    .offset(y: -(Pedestal.surface - Panels.baseSize * imp.scale * 0.16))
            } else {
                ImpEgg(hatchStart: isCurrent ? hatchStart : nil, pace: hatchPace, still: !isCurrent)
                    .frame(width: 112, height: 120)
                    .offset(y: -(Pedestal.surface - 4))
                    .contentShape(Rectangle())
                    .onTapGesture { hatch() }
                    .help("Crack the egg open (Return)")
                    .accessibilityLabel("Hatch a New Imp")
                    .accessibilityAddTraits(.isButton)
                    // At the side, a click belongs to the page (bring it to the middle), not the egg.
                    .allowsHitTesting(isCurrent)
            }
        }
        .overlay(alignment: .bottom) {
            // Just hatched: the rest of the shell flies off around it.
            if let imp, isCurrent, hatched == imp.id, hatchStart != nil {
                ImpEgg(hatchStart: hatchStart, pace: hatchPace)
                    .frame(width: 112, height: 120)
                    .offset(y: -(Pedestal.surface - 4))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.pageSize.width, height: Self.pageSize.height, alignment: .bottom)
        // A new egg grows in beside the Imp that just hatched.
        .modifier(Arrival(active: id == nil && eggArriving))
        .modifier(Waiting(focus: focus, interactive: !isCurrent, onTap: { step(offset) },
                          help: imp.map { String(localized: "Click to visit \($0.name).") } ?? String(localized: "Click to see the egg.")))
    }

    @ViewBuilder private func impFigure(_ imp: ImpProfile, offset: Int) -> some View {
        let side = Panels.baseSize * imp.scale
        Group {
            if imp.isActive && model.isHidden {
                // Out, but hidden: a little ghost under a sheet. Click it to bring everyone back.
                HidingImp(hue: imp.hue, clock: BodyClock(imp.id), center: {
                    offset == 0 ? router.slot(side: side).map { CGPoint(x: $0.midX, y: $0.midY) } : nil
                }, still: offset != 0)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    .contentShape(Rectangle())
                    .onTapGesture { if offset == 0 { withAnimation(.snappy(duration: 0.25)) { model.setHidden(false) } } }
                    .allowsHitTesting(offset == 0)
                    .help("\(imp.name) is hiding. Click to show the Imps on your desktop again.")
                    .accessibilityAddTraits(.isButton)
                    .contextMenu { contextMenu(for: imp) }
            } else if imp.isActive {
                // It's out on the desktop: an empty pedestal, wherever it is in the line. (In the
                // middle its own window draws it right here, until it's dragged away.)
                Color.clear
            } else if offset == 0 {
                StageImp(hue: imp.hue, mood: hatched == imp.id ? .happy : .idle,
                         performance: model.performances[imp.id], traits: imp.traits, clock: BodyClock(imp.id),
                         center: { router.slot(side: side).map { CGPoint(x: $0.midX, y: $0.midY) } })
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                    .contentShape(Rectangle())
                    .modifier(Arrival(active: hatched == imp.id))
                    .onTapGesture { router.openSettings(imp.id) }
                    .help("Click to open \(imp.name)'s settings.")
                    .accessibilityAddTraits(.isButton)
                    .contextMenu { contextMenu(for: imp) }
            } else {
                ImpPortrait(face: watching(imp, from: offset), shadow: true)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .animation(.snappy(duration: 0.3), value: model.isHidden)
        .accessibilityLabel(imp.isActive && model.isHidden ? String(localized: "\(imp.name), hiding") : imp.name)
    }

    /// The others watch whoever's in the doorway.
    private func watching(_ imp: ImpProfile, from offset: Int) -> Face {
        var face = impFace(hue: imp.hue, mood: .idle)
        face.lookX = offset < 0 ? 0.7 : -0.7
        face.lookY = 0.15
        return face
    }

    @ViewBuilder private func contextMenu(for imp: ImpProfile) -> some View {
        Button { router.openSettings(imp.id) } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
        Button { toggleActive(imp.id) } label: { Label(Self.release(imp), systemImage: imp.isActive ? "house.fill" : "flame.fill") }
        Button { router.renaming = true } label: { Label("Rename", systemImage: "pencil") }
        if model.isHidden {
            Button { withAnimation(.snappy(duration: 0.25)) { model.setHidden(false) } } label: {
                Label("Show Hidden Imps", systemImage: "eye")
            }
        }
        Divider()
        Button(role: .destructive) { deleting = imp.id } label: { Label("Say Goodbye to \(imp.name)…", systemImage: "trash") }
            .disabled(model.prefs.imps.count <= 1)
    }

    private func arrow(left: Bool, _ line: Line) -> some View {
        let enabled = !busy && (left ? line.index > 0 : line.index < line.pages.count - 1)
        return Button { step(left ? -1 : 1) } label: {
            RoundGlyph(systemName: left ? "chevron.left" : "chevron.right", size: 40, bold: true)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .scaleEffect(enabled ? 1 : 0.8)
        .animation(.snappy(duration: 0.2), value: enabled)
        .allowsHitTesting(enabled)
        .help(left ? "Go to the previous Imp (←)" : "Go to the next Imp (→)")
        .accessibilityLabel(left ? "Previous Imp" : "Next Imp")
        .accessibilityHidden(!enabled)
    }

    // MARK: Bottom

    @ViewBuilder private var controls: some View {
        VStack(spacing: 14) {
            if let imp = current {
                palette(for: imp)
                HStack(spacing: 14) {
                    let needsBrain = !model.isReady(imp.id)
                    Button { router.openSettings(imp.id, tab: needsBrain ? .brain : nil) } label: {
                        RoundGlyph(systemName: "slider.horizontal.3", size: 40)
                            // Needs a brain before it can chat: a dot, not words (nothing shifts).
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(Color.orange).frame(width: Self.badge, height: Self.badge)
                                    .overlay(Circle().strokeBorder(Dungeon.deep, lineWidth: 1.5))
                                    .opacity(needsBrain ? 1 : 0)
                            }
                    }
                        .buttonStyle(.plain)
                        .help(needsBrain ? String(localized: "\(imp.name) needs a brain before it can chat. Click to set one up.")
                                         : String(localized: "Change \(imp.name)'s looks, brain, tools and triggers."))
                        .accessibilityLabel(needsBrain ? "Settings, needs a brain" : "Settings")
                    activateButton(for: imp)
                    generalSettingsButton
                }
            } else {
                Color.clear.frame(height: 38)
                HStack(spacing: 14) {
                    // Balances the gear, so the big button stays centred.
                    Color.clear.frame(width: 40, height: 40)
                    Button { hatch() } label: { Label("Hatch a New Imp", systemImage: "sparkles").frame(width: Self.actionWidth) }
                        .buttonStyle(BigButtonStyle(hue: 0.08))
                        .disabled(busy)
                        .help("Crack the egg open (Return)")
                    generalSettingsButton
                }
            }
        }
        .frame(height: 104)
    }

    private func palette(for imp: ImpProfile) -> some View {
        HStack(spacing: 6) {
            ForEach(ImpProfile.colors, id: \.hue) { c in
                let picked = abs(imp.hue - c.hue) < 0.005
                let loved = imp.knowsFavorite && abs(imp.favoriteHue - c.hue) < 0.005
                Button { setHue(imp.id, c.hue) } label: {
                    Swatch(fill: AnyShapeStyle(Color.imp(c.hue)), picked: picked, loved: loved)
                }
                .buttonStyle(.plain)
                .help(loved ? LocalizedStringKey("\(c.name) is \(imp.name)'s favourite.") : LocalizedStringKey(c.name))
                .accessibilityLabel(loved ? LocalizedStringKey("\(c.name), favourite") : LocalizedStringKey(c.name))
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
            let custom = !ImpProfile.colors.contains { abs(imp.hue - $0.hue) < 0.005 }
            Button { pickingShade = true } label: {
                Swatch(fill: AnyShapeStyle(AngularGradient(colors: (0...6).map { Color.imp(Double($0) / 6) }, center: .center)),
                       picked: custom, loved: false)
            }
            .buttonStyle(.plain)
            .help("Pick any colour.")
            .accessibilityLabel("Any colour")
            .popover(isPresented: $pickingShade, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Any colour you like").font(.headline)
                    HueSlider(hue: Binding(get: { model.profile(imp.id)?.hue ?? 0 }, set: { setHue(imp.id, $0, animated: false) }))
                        .frame(width: 240)
                }
                .padding(14)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Dungeon.card))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
    }

    private func activateButton(for imp: ImpProfile) -> some View {
        Button { toggleActive(imp.id) } label: {
            Label(Self.release(imp), systemImage: imp.isActive ? "house.fill" : "flame.fill")
                .lineLimit(1).minimumScaleFactor(0.7)
                // A fixed width: "Let it out" and "Call it home" differ in length, and the buttons
                // beside it mustn't move when it changes.
                .frame(width: Self.actionWidth)
        }
        .buttonStyle(BigButtonStyle(hue: imp.hue, filled: !imp.isActive))
        .help(imp.isActive ? String(localized: "Call \(imp.name) back home into this window (Return).")
                           : String(localized: "Let \(imp.name) out onto your desktop right where it stands. It stays there when you close this window (Return)."))
    }

    /// Where you are among the Imps: each dot in its Imp's colour, the selected one a pill. With
    /// many Imps only a stretch around the selected one shows, and its ends shrink away.
    private func dots(_ line: Line) -> some View {
        let count = line.pages.count
        let first = min(max(line.index - Self.maxDots / 2, 0), max(count - Self.maxDots, 0))
        let range = first..<min(first + Self.maxDots, count)
        return HStack(spacing: 6) {
            ForEach(Array(line.pages.enumerated())[range], id: \.element) { i, id in
                let on = i == line.index
                let edge = (i == range.lowerBound && first > 0) || (i == range.upperBound - 1 && range.upperBound < count)
                Group {
                    if let id, let imp = model.profile(id) {
                        Capsule().fill(Color.imp(imp.hue).opacity(on ? 1 : 0.45))
                            .frame(width: on ? 18 : 7, height: 7)
                    } else {
                        Image(systemName: "plus").font(.system(size: 8, weight: .black))
                            .foregroundStyle(Dungeon.cream.opacity(on ? 0.9 : 0.4))
                            .frame(width: 9, height: 9)
                    }
                }
                .scaleEffect(edge ? 0.6 : 1)
                .contentShape(Rectangle().inset(by: -5))
                .onTapGesture { step(i - line.index) }
                .help(id.flatMap(model.profile).map { String(localized: "Go to \($0.name).") } ?? String(localized: "Go to the egg."))
            }
        }
        .frame(height: 10)
        .animation(glide, value: line.index)
        // One element for assistive technology: swipe up or down to move along the line.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Imps")
        .accessibilityValue(String(localized: "\(line.index + 1) of \(count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    /// The big button's words: out onto the desktop, or back into the doorway.
    static func release(_ imp: ImpProfile) -> String {
        let name = imp.name.isEmpty ? String(localized: "It") : imp.name
        return imp.isActive ? String(localized: "Call \(name) Home") : String(localized: "Let \(name) Out")
    }

    // MARK: Doing things

    private var deleteTitle: String {
        String(localized: "Say goodbye to \(deleting.flatMap(model.profile)?.name ?? String(localized: "this Imp"))?")
    }

    /// Moves `d` places along the line, stopping at either end.
    private func step(_ d: Int) {
        let line = line
        let to = min(max(line.index + d, 0), line.pages.count - 1)
        guard !busy, to != line.index else { return }
        router.renaming = false
        withAnimation(glide) { router.selection = line.pages[to] }
    }

    private func toggleActive(_ id: UUID) {
        guard let imp = model.profile(id) else { return }
        let slot = router.selection == id ? router.slot(side: Panels.baseSize * imp.scale) : nil
        if !imp.isActive {
            // Out it goes, exactly where it stands now.
            model.setActive(id, true, at: slot?.origin)
        } else if let slot, let fly = model.flyHome {
            // Fly back to the doorway, then step inside.
            fly(id, slot.origin) { model.setActive(id, false) }
        } else {
            model.setActive(id, false)
        }
    }

    private func setHue(_ id: UUID, _ hue: Double, animated: Bool = true) {
        guard let i = model.prefs.imps.firstIndex(where: { $0.id == id }) else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) { model.prefs.imps[i].hue = hue }
        } else {
            model.prefs.imps[i].hue = hue
        }
    }

    private func rename(_ id: UUID, _ name: String) {
        guard let i = model.prefs.imps.firstIndex(where: { $0.id == id }) else { return }
        model.prefs.imps[i].name = name
    }

    /// A new Imp comes out of the egg, the same way as an imported one.
    private func hatch() {
        guard !busy else { return }
        router.hatch([model.addImp(after: model.prefs.imps.last?.id)])
    }

    /// Cracks the waiting eggs one after another: the egg slides to the middle and cracks, the Imp
    /// steps out and the shell flies, and only then does the next egg grow in beside it. The ones
    /// after the first go quicker. When the stage is left this ends where it is: what hasn't
    /// hatched stays in the router and goes on when the stage comes back.
    private func playHatches() async {
        var played = 0
        do {
            while let id = router.unhatched.first {
                guard model.profile(id) != nil else { router.hatched(id); continue }
                guard played < Self.maxEggs else { router.hatchedAll(); break }
                let pace = played == 0 ? 1 : ImpEgg.quickPace
                hatched = nil
                eggShown = true
                if router.selection != nil {
                    withAnimation(glide) { router.selection = nil }
                    try await Task.sleep(for: .seconds(Self.settle))
                }
                hatchPace = pace
                hatchStart = Date()
                try await Task.sleep(for: .seconds(reduceMotion ? ImpEgg.reducedFade : ImpEgg.revealAt / pace))
                // The shell has opened: the Imp is in the egg's place, the shell's pieces fly on.
                eggShown = false
                router.hatched(id)
                hatched = id
                router.selection = id
                if !reduceMotion { try await Task.sleep(for: .seconds((ImpEgg.hatchDuration - ImpEgg.revealAt) / pace)) }
                hatchStart = nil
                played += 1
                eggArriving = true
                eggShown = true
                try await Task.sleep(for: .seconds(router.unhatched.isEmpty ? Self.linger : Self.beat))
            }
            router.finishHatching()
        } catch {}
        hatchStart = nil
        eggShown = true
        eggArriving = false
        hatched = nil
    }

    private func remove(_ id: UUID) {
        deleting = nil
        guard let next = model.sayGoodbye(id) else { return }
        withAnimation(.snappy) { router.selection = next }
    }
}

/// The Imps either side of the doorway: smaller and dimmer, brightening when you point at them.
/// Click one to bring it to the middle. `focus` runs from 0 (in the doorway) to 1 (at the side), so
/// the pages grow and fade smoothly as a drag moves them.
private struct Waiting: ViewModifier {
    let focus: CGFloat
    let interactive: Bool
    let onTap: () -> Void
    let help: String
    @State private var hover = false

    func body(content: Content) -> some View {
        // Always the same modifiers (only their values change), so moving to or from the middle
        // animates smoothly instead of swapping views.
        let t = min(focus, 1)
        let lit = hover && interactive
        content
            .saturation(1 - t * (lit ? 0.05 : 0.3))
            .opacity(1 - t * (lit ? 0.15 : 0.5))
            .scaleEffect(1 - t * (1 - ImpStage.neighbourScale * (lit ? 1.05 : 1)), anchor: .bottom)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = interactive && $0 }
            .onTapGesture { if interactive { onTap() } }
            .help(interactive ? help : "")
    }
}

/// Grows from its pedestal when it first appears, if told to: a new egg arriving, an Imp stepping
/// out of its shell. Only the first appearance counts, so scrolling back later is plain.
private struct Arrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived: Bool

    init(active: Bool) { _arrived = State(initialValue: !active) }

    func body(content: Content) -> some View {
        content
            .scaleEffect(arrived || reduceMotion ? 1 : 0.2, anchor: .bottom)
            .opacity(arrived ? 1 : 0)
            .onAppear {
                guard !arrived else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.7)) { arrived = true }
            }
    }
}

/// Hands the stage's NSView to the router, so positions on it can be found on screen at any time.
private struct StageAnchor: NSViewRepresentable {
    let router: HomeRouter

    func makeNSView(context: Context) -> NSView {
        let v = Passthrough()
        router.stageAnchor = v
        return v
    }

    func updateNSView(_ view: NSView, context: Context) { router.stageAnchor = view }

    private final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
