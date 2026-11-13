import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The window's content: the canvas, an Imp's settings, or the settings every Imp shares. The whole
/// window is the canvas. The title bar is transparent, and a strip along the top drags the window.
struct HomeView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A settings screen slides in from the side, or just fades with Reduce Motion.
    private var slide: AnyTransition { reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity) }

    var body: some View {
        ZStack {
            // The canvas shows the background the user chose. Every settings page sits on the app's one flat
            // surface, whatever the canvas shows (a picture, a tile or a colour would only make text harder to read).
            if router.screen == .home {
                CanvasBackdrop(background: model.prefs.background).transition(.opacity)
            } else {
                Backdrop().transition(.opacity)
            }
            Group {
                switch router.screen {
                case .home:
                    VStack(spacing: 0) {
                        WindowDragStrip().frame(height: CGFloat(Behavior.dragStripPoints))
                        ImpCanvas(model: model, router: router)
                    }
                    .overlay(alignment: .topTrailing) { CornerButtons(model: model, router: router) }
                    .overlay(alignment: .bottom) { UndoOverlay(model: model, router: router) }
                    .transition(.opacity)
                case .imp(let id):
                    if model.profile(id) != nil {
                        ImpSettingsView(model: model, router: router, id: id)
                            .id(id)
                            .transition(slide)
                    } else {
                        Color.clear.onAppear { router.screen = .home }
                    }
                case .general:
                    GeneralSettingsView(model: model, router: router)
                        .transition(slide)
                }
            }
        }
        .sheet(item: $router.kitFlow) { flow in
            let tint = (flow.imp ?? router.selection).flatMap(model.profile).map { Color.imp($0.hue) } ?? Color.imp
            KitFlowSheet(model: model, flow: flow, router: router)
                .environment(\.impTint, tint)
                .tint(tint)
        }
        .sheet(isPresented: Binding(get: { router.firstRun != nil }, set: { if !$0 { router.firstRun = nil } })) {
            if let id = router.firstRun, let profile = model.profile(id) {
                FirstRunHost(app: model, id: id) { router.firstRun = nil }
                    .environment(\.impTint, Color.imp(profile.hue))
                    .tint(Color.imp(profile.hue))
            }
        }
        .sheet(item: $router.talk) { talk in
            let tint = model.profile(talk.imp).map { Color.imp($0.hue) } ?? Color.imp
            TalkSheet(model: model, request: talk)
                .environment(\.impTint, tint)
                .tint(tint)
        }
        .confirmationDialog(goodbyeTitle, isPresented: Binding(get: { router.saying != nil }, set: { if !$0 { router.saying = nil } }),
                            titleVisibility: .visible) {
            Button { if let id = router.saying { HomeActions(model: model, router: router).sayGoodbye(id) } } label: {
                Text("goodbye.confirm")
            }
            Button(role: .cancel) { router.saying = nil } label: {
                Text(words("goodbye.cancel", router.saying.flatMap(model.profile)?.name ?? ""))
            }
        } message: {
            Text("goodbye.message")
        }
        .alert(Text("background.picture_failed"), isPresented: $router.pictureFailed) {}
        .environment(\.stageAwake, router.isAwake)
        .environment(\.tintInk, model.prefs.controlInk.tintInk)
        .tint(Color.imp)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background {
            // ⌘[ goes back. (The menu bar has ⌘, for the settings every Imp shares.)
            Button(String("")) { router.goHome() }
                .keyboardShortcut("[", modifiers: .command).opacity(0)
        }
    }

    private var goodbyeTitle: String {
        words("goodbye.title", router.saying.flatMap(model.profile)?.name ?? "")
    }
}

/// The canvas's actions in the top trailing corner, each one click: New Imp, Show hidden (only while some
/// Imps are hidden, with how many) and Settings. The same actions are in the right-click menu and the menu bar.
private struct CornerButtons: View {
    let model: AppModel
    let router: HomeRouter

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            HoverIconButton(systemName: "plus", help: "menu.canvas.new_imp", tint: Tone.muted) { actions.newImp() }
            if model.hiddenCount > 0 {
                HoverIconButton(systemName: "eye", help: "home.corner.show_hidden", tint: Tone.muted) { actions.showHidden() }
                    .overlay(alignment: .topTrailing) {
                        Text(model.hiddenCount, format: .number)
                            .font(Typeface.small)
                            .foregroundStyle(OnTint(Color.imp))
                            .padding(.horizontal, Spacing.snug)
                            .background(Capsule().fill(TintFill(Color.imp)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityValue(Text(model.hiddenCount, format: .number))
            }
            HoverIconButton(systemName: "gearshape", help: "menu.canvas.settings", tint: Tone.muted) { actions.openSettings() }
        }
        // Centred in a bar's height, so the gear is as far from the right as from the top.
        .padding(.trailing, CornerInset.bar(height: Metrics.barHeight))
        .frame(height: Metrics.barHeight)
        .impAnimation(ImpDesign.Motion.fade, value: model.hiddenCount > 0)
    }
}

/// The Undo bar after an Imp is let out, sent home or hidden. It goes away by itself.
private struct UndoOverlay: View {
    let model: AppModel
    let router: HomeRouter

    var body: some View {
        if let offer = router.undo {
            UndoBar(message: words(Self.key(offer.kind), model.profile(offer.imp)?.name ?? ""), undoTitle: "common.undo") {
                router.undoOffered()
            }
            .padding(.bottom, Spacing.huge)
            .transition(.opacity)
            .task(id: offer.expires) {
                try? await Task.sleep(for: .seconds(max(0, offer.expires.timeIntervalSinceNow)))
                if !Task.isCancelled, router.undo == offer { router.dismissUndo() }
            }
        }
    }

    private static func key(_ kind: UndoOffer.Kind) -> LocalizedStringResource {
        switch kind {
        case .letOut: "imp.out.undo"
        case .sendHome: "imp.home.undo"
        case .hide: "imp.hide.undo"
        }
    }
}

/// The strip along the top of the window that drags it. The canvas below does not.
private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Strip() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
