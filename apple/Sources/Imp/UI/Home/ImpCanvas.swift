import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The home screen: a calm canvas with the Imps standing on it. Drag one to move it. Nothing else is
/// drawn on it. The menu is a right click on empty space (or the more button), and an Imp has its own.
struct ImpCanvas: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    @FocusState private var focus: UUID?
    /// The box being drawn on empty space to pick Imps, while the drag lasts.
    @State private var box: CGRect?
    /// The picks the box adds to (⌘ or ⇧ held when it started), else none.
    @State private var boxBase: Set<UUID> = []

    private var onCanvas: [UUID] { model.prefs.imps.map(\.id).filter(model.isOnCanvas) }

    /// Where each Imp's figure is drawn, for the box that picks them.
    private func centres(_ ids: [UUID], in size: CGSize) -> [UUID: CGPoint] {
        var out: [UUID: CGPoint] = [:]
        for id in ids {
            guard let imp = model.profile(id) else { continue }
            out[id] = CanvasLayout.point(of: router.places[id] ?? CGPoint(x: 0.5, y: 0.5), in: size, figure: Panels.baseSize * imp.scale)
        }
        return out
    }

    var body: some View {
        let ids = onCanvas
        GeometryReader { geo in
            ZStack {
                // Empty space: a right click here opens the canvas menu.
                Color.clear
                    .contentShape(Rectangle())
                    // A right click here opens the canvas menu, an AppKit menu for its row of buttons. Other clicks pass.
                    .overlay {
                        SecondaryClickMenu { [model, router] in
                            let menu = CanvasEmptyMenu(model: model, router: router)
                            router.openMenu = menu      // menu item targets are weak: keep it alive while open
                            return menu.make()
                        }
                    }
                    // A click on empty space lets the group go. A drag draws a box that picks the Imps inside it.
                    .onTapGesture { router.clearPicks() }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(CanvasImp.space))
                        .onChanged { drag in
                            let adding = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                            if box == nil { boxBase = adding ? router.picked.union([router.selection].compactMap { $0 }) : [] }
                            let rect = ImpPicks.box(from: drag.startLocation, to: drag.location)
                            box = rect
                            let inside = ImpPicks.inside(rect, centres: centres(ids, in: geo.size))
                            router.picked = boxBase.union(inside)
                            if let first = ids.first(where: router.picked.contains), !(router.selection.map(router.picked.contains) ?? false) {
                                router.selection = first
                            }
                        }
                        .onEnded { _ in box = nil })
                if let box {
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .fill(Tone.accent.opacity(Opacity.tintFill))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if model.prefs.imps.isEmpty {
                    EmptyCanvas(action: { HomeActions(model: model, router: router).newImp() })
                }
                ForEach(ids, id: \.self) { id in
                    CanvasImp(model: model, router: router, id: id, size: geo.size, focus: $focus)
                }
                HiddenFloor(model: model, router: router, size: geo.size)
            }
            .coordinateSpace(.named(CanvasImp.space))
        }
        .background(CanvasAnchor(router: router))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("home.canvas.label"))
        .accessibilityHint(Text("home.canvas.hint"))
        .onChange(of: ids, initial: true) { _, ids in
            for id in ids where router.places[id] == nil {
                router.places[id] = CanvasLayout.freePlace(taking: ids.compactMap { router.places[$0] })
            }
        }
        .onChange(of: focus) { _, id in if let id { router.selection = id } }
        .onExitCommand { router.clearPicks() }
        .onCommand(#selector(NSText.selectAll(_:))) { router.pickAll(ids) }
    }
}

/// One Imp on the canvas.
private struct CanvasImp: View {
    static let space = "canvas"
    /// How far an arrow key moves an Imp, and how far with Shift.
    private static let step: CGFloat = 16
    private static let bigStep: CGFloat = 64
    /// How much wider than its figure a name may be before it is cut (a ratio of the figure).
    private static let nameReach: CGFloat = 1.5

    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let id: UUID
    let size: CGSize
    var focus: FocusState<UUID?>.Binding
    /// Where the pointer holds the Imp, from its middle, in canvas points. Set for the length of a drag.
    @State private var grab: CGSize?
    /// Where the Imp is drawn while it is dragged: it follows the pointer unclamped and is kept inside
    /// the canvas only when it is put down.
    @State private var dragged: CGPoint?
    @State private var popped: Bool
    /// The focus came from the keyboard (Tab or an arrow), so the ring shows. A click focuses without it.
    @State private var viaKeyboard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, router: HomeRouter, id: UUID, size: CGSize, focus: FocusState<UUID?>.Binding) {
        self.model = model; self.router = router; self.id = id; self.size = size; self.focus = focus
        _popped = State(initialValue: !router.arriving.contains(id))
    }

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        if let imp = model.profile(id) {
            let side = Panels.baseSize * imp.scale
            let centre = CanvasLayout.point(of: router.places[id] ?? CGPoint(x: 0.5, y: 0.5), in: size, figure: side)
            let drawn = dragged ?? centre
            let selected = router.isPicked(id)
            let tint = Color.imp(imp.hue)
            VStack(spacing: Spacing.hairline) {
                figure(imp, side: side)
                    .frame(width: side, height: side)
                    .environment(\.impTint, tint)
                    .focusRing(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous), shown: focus.wrappedValue == id && viaKeyboard)
                name(imp, tint: tint, selected: selected, side: side)
                    .frame(width: side * Self.nameReach, height: CanvasLayout.nameRoom - Spacing.hairline)
            }
            .impAnimation(ImpDesign.Motion.quick, value: selected)
            // A right click opens the Imp's own menu: the same card as on the desktop.
            .overlay {
                SecondaryClickMenu { [model, router, id] in
                    // On one of a group: the group's menu. On any other Imp: that Imp's, and the group is let go.
                    let group = ImpPicks.group(of: id, picked: router.picked, order: model.prefs.imps.map(\.id))
                    if group.count > 1 {
                        let menu = CanvasGroupMenu(model: model, router: router, ids: group)
                        router.openMenu = menu      // menu item targets are weak: keep it alive while open
                        return menu.make()
                    }
                    router.clearPicks()
                    router.select(id)
                    let menu = CanvasImpMenu(model: model, router: router, id: id)
                    router.openMenu = menu
                    return menu.make()
                }
            }
            .scaleEffect(popped || reduceMotion ? 1 : 0.2, anchor: .center)
            .opacity(popped ? 1 : 0)
            .position(x: drawn.x, y: drawn.y + CanvasLayout.nameRoom / 2)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .onChanged { follow($0, centre: centre, side: side) }
                .onEnded { _ in drop(side: side) })
            .gesture(TapGesture(count: 2).onEnded { actions.click(id, count: 2) },
                     including: model.prefs.waitsForMoreClicks(on: id) ? .all : .subviews)
            .onTapGesture {
                viaKeyboard = false
                // ⌘- or ⇧-click: in or out of the group, and nothing else.
                let keys = NSEvent.modifierFlags
                if keys.contains(.command) || keys.contains(.shift) { return router.togglePick(id) }
                router.clearPicks()
                actions.click(id, count: 1)
            }
            .focusable()
            .focused(focus, equals: id)
            .focusEffectDisabled()
            .onChange(of: focus.wrappedValue == id) { _, focused in
                viaKeyboard = focused && NSApp.currentEvent?.type == .keyDown
            }
            .onKeyPress(.return) { actions.talk(id); return .handled }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let d = press.modifiers.contains(.shift) ? Self.bigStep : Self.step
                let by = Self.direction(of: press.key)
                viaKeyboard = true
                move(to: CGPoint(x: centre.x + by.width * d, y: centre.y + by.height * d), side: side)
                return .handled
            }
            .onAppear {
                guard !popped else { return }
                withImpAnimation(ImpDesign.Motion.pop, reduceMotion: reduceMotion) { popped = true }
                router.arrived(id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(actions.label(id))
            .accessibilityHint(Text("imp.drag.hint"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { actions.openBubble(id) }
            .accessibilityAction(named: Text(words("imp.a11y.talk", imp.name))) { actions.talk(id) }
            .accessibilityAction(named: Text(words("imp.a11y.settings", imp.name))) { actions.openImpSettings(id) }
            .accessibilityAction(named: Text(words("imp.a11y.hide", imp.name))) { actions.hide(id) }
            .accessibilityAction(named: Text(words(imp.awayOn != nil ? "imp.a11y.call_home" : imp.isActive ? "imp.a11y.send_home" : "imp.a11y.let_out", imp.name))) {
                actions.toggleActive(id)
            }
        }
    }

    /// The name (and the phone it is on) in a small pebble: soft while the Imp rests, the Imp's colour while selected.
    private func name(_ imp: ImpProfile, tint: Color, selected: Bool, side: CGFloat) -> some View {
        HStack(spacing: Spacing.tight) {
            Text(imp.name)
                .font(Typeface.label)
                .foregroundStyle(selected ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                .lineLimit(1)
            if let device = imp.awayOn {
                PhoneBadge(label: words("imp.phone.label", model.link.name(of: device) ?? "iPhone"))
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.tight)
        .background(Capsule().fill(selected ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
    }

    /// The Imp follows the pointer, held by the same spot all along. The moment its frame is no longer
    /// wholly inside the window it is handed to its own desktop panel, exactly where it is drawn.
    private func follow(_ drag: DragGesture.Value, centre: CGPoint, side: CGFloat) {
        router.select(id)
        let held = grab ?? CGSize(width: drag.startLocation.x - centre.x, height: drag.startLocation.y - centre.y)
        grab = held
        let target = CGPoint(x: drag.location.x - held.width, y: drag.location.y - held.height)
        dragged = target
        guard let canvas = router.canvasOnScreen, let arena = HomeWindow.shared.window?.frame else { return }
        let figure = CanvasLayout.screenFrame(centre: target, figure: side, canvas: canvas)
        guard ImpDrag.whileDragging(isFree: false, figure: figure, arena: arena) == .letOut else { return }
        grab = nil
        dragged = nil
        actions.dragOut(id, figure: figure, pointer: CanvasLayout.screenPoint(drag.location, canvas: canvas))
    }

    /// Put down inside the window: it settles within the canvas.
    private func drop(side: CGFloat) {
        let landing = dragged
        withImpAnimation(ImpDesign.Motion.settle, reduceMotion: reduceMotion) {
            if let landing { move(to: landing, side: side) }
            grab = nil
            dragged = nil
        }
    }

    @ViewBuilder private func figure(_ imp: ImpProfile, side: CGFloat) -> some View {
        // An Imp with no Brain sleeps on the home screen too, as in its settings and the first run.
        StageImp(hue: imp.hue, mood: model.isReady(id) ? .idle : .sleepy, performance: model.performances[id],
                 traits: imp.traits, clock: BodyClock(id),
                 center: { router.slot(of: id, side: side).map { CGPoint(x: $0.midX, y: $0.midY) } })
    }

    private static func direction(of key: KeyEquivalent) -> CGSize {
        switch key {
        case .leftArrow: CGSize(width: -1, height: 0)
        case .rightArrow: CGSize(width: 1, height: 0)
        case .upArrow: CGSize(width: 0, height: -1)
        default: CGSize(width: 0, height: 1)
        }
    }

    private func move(to point: CGPoint, side: CGFloat) {
        router.places[id] = CanvasLayout.place(at: point, in: size, figure: side)
    }
}

/// The empty canvas: one prompt in the middle. It goes away as soon as there is an Imp.
struct EmptyCanvas: View {
    var action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Text("home.empty.title").font(Typeface.title).foregroundStyle(Tone.text)
            Text("home.empty.hint").font(Typeface.body).foregroundStyle(Tone.muted).multilineTextAlignment(.center)
            Button(action: action) { Text("home.empty.new_imp") }
                .buttonStyle(.imp(.primary))
        }
        .padding(Spacing.page)
        .accessibilityElement(children: .contain)
    }
}

/// Hands the canvas's NSView to the router, so positions on it can be found on screen at any time.
private struct CanvasAnchor: NSViewRepresentable {
    let router: HomeRouter

    func makeNSView(context: Context) -> NSView {
        let v = Passthrough()
        router.canvasAnchor = v
        return v
    }

    func updateNSView(_ view: NSView, context: Context) { router.canvasAnchor = view }

    private final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
