import AppKit
import ImpKit
import SwiftUI

/// The home screen: one Imp in the doorway, its name above, its colour and a row of actions
/// below (settings, let it out or call it home, more). Arrows (or ← →, or a swipe)
/// visit the others, who wait at either side watching. The egg at the end hatches a new one.
/// Click a resting Imp to open its settings.
struct ImpStage: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    @State private var drag: CGFloat = 0
    @State private var hatched: UUID?
    /// When the egg started cracking open (nil = resting).
    @State private var hatchStart: Date?
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

    private var pages: [UUID?] { model.prefs.imps.map(\.id) + [nil] }
    private var index: Int { pages.firstIndex(of: router.selection) ?? 0 }
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
        VStack(spacing: 0) {
            topBar
            header
            Spacer(minLength: 6)
            stage
            Spacer(minLength: 10)
            controls
                .padding(.bottom, 12)
            dots
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.impTint, Color.imp(current?.hue ?? 0.08))
        .focusable()
        .focusEffectDisabled()
        .focused($stageFocused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.return) {
            if let imp = current { toggleActive(imp.id) } else { hatch() }
            return .handled
        }
        .onAppear { stageFocused = true }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Say Goodbye", role: .destructive) {
                if let id = deleting { remove(id) }
            }
        } message: {
            Text("Its looks, brain settings, tools, folder and shortcuts go with it. This can't be undone.")
        }
    }

    // MARK: Top

    /// The title bar row: just the gear, level with the traffic lights.
    private var topBar: some View {
        TopBar {
            EmptyView()
        } trailing: {
            Button { withAnimation(.snappy(duration: 0.28)) { router.screen = .general } } label: {
                RoundGlyph(systemName: "gearshape.fill", size: 26)
            }
            .buttonStyle(.plain)
            .help("Settings for all Imps: brain keys, manners, animations, hearing, permissions (⌘,)")
            .accessibilityLabel("Settings for all Imps")
        }
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
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { geo in
            let floor = geo.size.height - Self.floorInset
            let doorHeight = min(geo.size.height - 10, 330)
            let figureMid = Self.figureRect(stage: geo.size, side: Panels.baseSize).midY
            ZStack {
                Doorway()
                    .frame(width: 300 + 2 * Doorway.torchRoom, height: doorHeight)
                    .position(x: geo.size.width / 2, y: floor - doorHeight / 2 + 12)
                ForEach(Array(pages.enumerated()), id: \.element) { i, id in
                    let d = CGFloat(i - index)
                    if abs(d) <= 1.5 {
                        page(id, offset: i - index)
                            .position(x: geo.size.width / 2 + d * Self.spacing(width: geo.size.width) + drag * (i == index ? 1 : 0.85),
                                      y: floor - Self.pageSize.height / 2)
                            .zIndex(i == index ? 1 : 0)
                    }
                }
                arrow(left: true).position(x: 36, y: figureMid)
                arrow(left: false).position(x: geo.size.width - 36, y: figureMid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.width * 0.8 }
                .onEnded { v in
                    let goTo = v.predictedEndTranslation.width < -90 ? 1 : v.predictedEndTranslation.width > 90 ? -1 : 0
                    withAnimation(.snappy(duration: 0.3)) { drag = 0 }
                    if goTo != 0 { step(goTo) }
                })
        }
        // Two fingers on the trackpad flick between Imps, the page following them.
        .onTrackpadSwipe { swipe in
            switch swipe {
            case .follow(let x): drag = x * 0.8
            case .commit(let pages):
                withAnimation(.snappy(duration: 0.3)) { drag = 0 }
                step(pages)
            case .cancel: withAnimation(.snappy(duration: 0.3)) { drag = 0 }
            }
        }
        // The stage's place on screen, for the selected Imp's slot (see `HomeRouter.slot`).
        .background(StageAnchor(router: router))
        .frame(minHeight: 250, maxHeight: 330)
    }

    /// One position on the stage: an Imp standing on its pedestal, or the egg. `offset` is how
    /// many places from the middle it is (0 = the selected one).
    @ViewBuilder private func page(_ id: UUID?, offset: Int) -> some View {
        let imp = id.flatMap(model.profile)
        let isCurrent = offset == 0
        ZStack(alignment: .bottom) {
            Pedestal(hue: imp?.hue ?? 0.08, lit: isCurrent && (imp?.isActive != true || model.isHidden))
                .frame(width: 170)
            if let imp {
                impFigure(imp, offset: offset)
                    .offset(y: -(Pedestal.surface - Panels.baseSize * imp.scale * 0.16))
            } else {
                ImpEgg(hatchStart: isCurrent ? hatchStart : nil)
                    .frame(width: 112, height: 120)
                    .offset(y: -(Pedestal.surface - 4))
                    .contentShape(Rectangle())
                    .onTapGesture { hatch() }
                    .help("Hatch a new Imp")
                    // At the side, a click belongs to the page (bring it to the middle), not the egg.
                    .allowsHitTesting(isCurrent)
            }
        }
        .overlay(alignment: .bottom) {
            // Just hatched: the rest of the shell flies off around it.
            if let imp, isCurrent, hatched == imp.id, let hatchStart {
                ImpEgg(hatchStart: hatchStart)
                    .frame(width: 112, height: 120)
                    .offset(y: -(Pedestal.surface - 4))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.pageSize.width, height: Self.pageSize.height, alignment: .bottom)
        .modifier(Waiting(active: !isCurrent, onTap: { go(to: index + offset) },
                          help: imp.map { "Visit \($0.name)" } ?? "A new Imp"))
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
                    .contextMenu { contextMenu(for: imp) }
            } else if imp.isActive {
                // It's out on the desktop: an empty pedestal, wherever it is in the line. (In the
                // middle its own window draws it right here, until it's dragged away.)
                Color.clear
            } else if offset == 0 {
                StageImp(hue: imp.hue, mood: hatched == imp.id ? .happy : .idle,
                         performance: model.performances[imp.id], clock: BodyClock(imp.id),
                         center: { router.slot(side: side).map { CGPoint(x: $0.midX, y: $0.midY) } })
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                    .contentShape(Rectangle())
                    .onTapGesture { router.openSettings(imp.id) }
                    .help("Open \(imp.name)'s settings")
                    .contextMenu { contextMenu(for: imp) }
            } else {
                ImpPortrait(face: watching(imp, from: offset), shadow: true)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .animation(.snappy(duration: 0.3), value: model.isHidden)
        .accessibilityLabel(imp.isActive && model.isHidden ? "\(imp.name), hiding" : imp.name)
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

    private func arrow(left: Bool) -> some View {
        let enabled = left ? index > 0 : index < pages.count - 1
        return Button { step(left ? -1 : 1) } label: {
            RoundGlyph(systemName: left ? "chevron.left" : "chevron.right", size: 40, bold: true)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .scaleEffect(enabled ? 1 : 0.8)
        .animation(.snappy(duration: 0.2), value: enabled)
        .allowsHitTesting(enabled)
        .help(left ? "Previous Imp (←)" : "Next Imp (→)")
        .accessibilityLabel(left ? "Previous Imp" : "Next Imp")
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
                                Circle().fill(Color.orange).frame(width: 9, height: 9)
                                    .overlay(Circle().strokeBorder(Dungeon.deep, lineWidth: 1.5))
                                    .opacity(needsBrain ? 1 : 0)
                            }
                    }
                        .buttonStyle(.plain)
                        .help(needsBrain ? "\(imp.name) needs a brain before it can chat: set it up"
                                         : "\(imp.name)'s settings: looks, brain, tools, shortcuts")
                        .accessibilityLabel("Settings")
                    activateButton(for: imp)
                    Menu { contextMenu(for: imp) } label: { RoundGlyph(systemName: "ellipsis", size: 40, bold: true) }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More: rename, say goodbye")
                        .accessibilityLabel("More")
                }
            } else {
                Color.clear.frame(height: 38)
                Button { hatch() } label: { Label("Hatch a New Imp", systemImage: "sparkles").frame(width: Self.actionWidth) }
                    .buttonStyle(BigButtonStyle(hue: 0.08))
                    .disabled(hatchStart != nil)
                    .help("Crack the egg open (Return)")
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
                .help(loved ? "\(c.name): \(imp.name)'s favourite" : c.name)
                .accessibilityLabel(loved ? "\(c.name), favourite" : c.name)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
            let custom = !ImpProfile.colors.contains { abs(imp.hue - $0.hue) < 0.005 }
            Button { pickingShade = true } label: {
                Swatch(fill: AnyShapeStyle(AngularGradient(colors: (0...6).map { Color.imp(Double($0) / 6) }, center: .center)),
                       picked: custom, loved: false)
            }
            .buttonStyle(.plain)
            .help("Any colour")
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
        .help(imp.isActive ? "Call \(imp.name) back home into this window (Return)"
                           : "Let \(imp.name) out right where it stands: drag it anywhere. It stays when you close this window. (Return)")
    }

    /// Where you are among the Imps: each dot in its Imp's colour, the selected one a pill.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element) { i, id in
                let on = i == index
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
                .contentShape(Rectangle().inset(by: -5))
                .onTapGesture { go(to: i) }
                .help(id.flatMap(model.profile)?.name ?? "A new Imp")
            }
        }
        .frame(height: 10)
        .animation(.snappy(duration: 0.25), value: index)
    }

    /// The big button's words: out onto the desktop, or back into the doorway.
    static func release(_ imp: ImpProfile) -> String {
        let name = imp.name.isEmpty ? "It" : imp.name
        return imp.isActive ? "Call \(name) Home" : "Let \(name) Out"
    }

    // MARK: Doing things

    private var deleteTitle: String {
        "Say goodbye to \(deleting.flatMap(model.profile)?.name ?? "this Imp")?"
    }

    private func step(_ d: Int) { go(to: index + d) }

    private func go(to i: Int) {
        guard pages.indices.contains(i), i != index else { return }
        router.renaming = false
        withAnimation(.snappy(duration: 0.32)) { router.selection = pages[i] }
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

    /// The egg cracks open, and halfway through the new Imp steps out of it.
    private func hatch() {
        guard hatchStart == nil else { return }
        let start = Date()
        hatchStart = start
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : ImpEgg.revealAt))
            let id = model.addImp(after: model.prefs.imps.last?.id)
            hatched = id
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { router.selection = id }
            try? await Task.sleep(for: .seconds(max(ImpEgg.hatchDuration - ImpEgg.revealAt, 0.2)))
            if hatchStart == start { hatchStart = nil }
            try? await Task.sleep(for: .seconds(1.2))
            if hatched == id { hatched = nil }
        }
    }

    private func remove(_ id: UUID) {
        let i = model.prefs.imps.firstIndex { $0.id == id } ?? 0
        deleting = nil
        model.setActive(id, false)
        model.removeImp(id)
        let ids = model.prefs.imps.map(\.id)
        withAnimation(.snappy) { router.selection = ids[min(i, ids.count - 1)] }
    }
}

/// The Imps either side of the doorway: smaller and dimmer, brightening when you point at them.
/// Click one to bring it to the middle.
private struct Waiting: ViewModifier {
    let active: Bool
    let onTap: () -> Void
    let help: String
    @State private var hover = false

    func body(content: Content) -> some View {
        // Always the same modifiers (only their values change), so moving to or from the middle
        // animates smoothly instead of swapping views.
        content
            .saturation(active ? (hover ? 0.95 : 0.7) : 1)
            .opacity(active ? (hover ? 0.85 : 0.5) : 1)
            .scaleEffect(active ? ImpStage.neighbourScale * (hover ? 1.05 : 1) : 1, anchor: .bottom)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = active && $0 }
            .onTapGesture { if active { onTap() } }
            .help(active ? help : "")
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
