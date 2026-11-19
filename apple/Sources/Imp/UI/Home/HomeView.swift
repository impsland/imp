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
            // The canvas shows the page the Imps drew. Every settings page sits on the app's one flat surface,
            // whatever the canvas shows. The canvas stays underneath (kept as a still picture, its page paused), so
            // coming back home shows it at once.
            CanvasBackdrop(html: model.prefs.background, live: router.isAwake && router.screen == .home)
            if router.screen != .home {
                Backdrop().transition(.opacity)
            }
            Group {
                switch router.screen {
                case .home:
                    VStack(spacing: 0) {
                        WindowDragStrip().frame(height: CGFloat(Behavior.dragStripPoints))
                        ImpCanvas(model: model, router: router)
                    }
                    .overlay { CornerButtons(model: model, router: router, corners: .platform) }
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
                case .devices:
                    DevicesScreen(model: model, router: router)
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
            if let target = router.firstRun, let profile = target.profile(in: model.prefs.imps) {
                FirstRunHost(app: model, target: target, hatched: { router.hatch([$0]) }) { router.firstRun = nil }
                    .environment(\.impTint, Color.imp(profile.hue))
                    .tint(Color.imp(profile.hue))
            }
        }
        .sheet(isPresented: $router.linkingDevice) {
            LinkDeviceSheet(model: model, mode: .show)
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
        // Several picked Imps at once: asked once, for all of them.
        .confirmationDialog(words("goodbye.many.title", router.sayingMany?.count ?? 0),
                            isPresented: Binding(get: { router.sayingMany != nil }, set: { if !$0 { router.sayingMany = nil } }),
                            titleVisibility: .visible) {
            Button(role: .destructive) { if let ids = router.sayingMany { HomeActions(model: model, router: router).sayGoodbye(ids) } } label: {
                Text("goodbye.confirm")
            }
            Button(role: .cancel) { router.sayingMany = nil } label: { Text("goodbye.many.cancel") }
        } message: {
            Text(verbatim: (router.sayingMany ?? []).compactMap { model.profile($0)?.name }.formatted(.list(type: .and)) + "\n\n"
                 + String(localized: "goodbye.many.message"))
        }
        // An Imp away on another device is never out of reach: a click on it, or Call Home in its menu, asks this.
        .confirmationDialog(callHomeTitle, isPresented: Binding(get: { router.callingHome != nil }, set: { if !$0 { router.callingHome = nil } }),
                            titleVisibility: .visible) {
            Button { if let id = router.callingHome { HomeActions(model: model, router: router).callHome(id) } } label: {
                Text("menu.imp.call_home")
            }
            Button("common.cancel", role: .cancel) { router.callingHome = nil }
        } message: {
            Text(words("imp.call_home.message", callHomeDevice))
        }
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

    private var callHomeTitle: String {
        words("imp.call_home.title", router.callingHome.flatMap(model.profile)?.name ?? "", callHomeDevice)
    }

    /// The device that holds the Imp being called home, by name (it may be a device no longer linked).
    private var callHomeDevice: String {
        router.callingHome.flatMap(model.profile)?.awayOn.flatMap { model.link.name(of: $0) } ?? String(localized: "imp.call_home.other_device")
    }

    private var goodbyeTitle: String {
        words("goodbye.title", router.saying.flatMap(model.profile)?.name ?? "")
    }
}

/// The canvas's actions, each one click, spread over the three corners the window's own buttons leave
/// free (`HomeCorners`): Settings in the other top corner, New Imp below it (with Show hidden beside it,
/// only while some Imps are hidden, with how many) and Devices below the window's buttons (a dot while a
/// linked device is connected). The same actions are in the right-click menu and the menu bar.
struct CornerButtons: View {
    let model: AppModel
    let router: HomeRouter
    let corners: HomeCorners
    @Environment(\.layoutDirection) private var direction

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        ZStack {
            corner(corners.settings) { settings }
            corner(corners.newImp) {
                // New Imp keeps the very corner. Show hidden comes and goes on its inner side.
                if corners.newImp.isLeft {
                    newImp
                    showHidden
                } else {
                    showHidden
                    newImp
                }
            }
            corner(corners.devices) { devices }
        }
        .impAnimation(ImpDesign.Motion.fade, value: model.hiddenCount > 0)
    }

    /// A row of buttons in `place`, centred in a bar's height, so the outer button is as far from the side as
    /// from the top (or the bottom).
    private func corner(_ place: HomeCorners.Corner, @ViewBuilder _ buttons: () -> some View) -> some View {
        // Rows are laid out left to right in the corner, whatever the language's direction.
        HStack(spacing: Spacing.tight) { buttons() }
            .environment(\.layoutDirection, .leftToRight)
            .padding(place.outerEdge(direction), CornerInset.bar(height: Metrics.barHeight))
            .frame(height: Metrics.barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place.alignment(direction))
    }

    private var settings: some View {
        HoverIconButton(systemName: "gearshape", help: "menu.canvas.settings", tint: Tone.muted) { actions.openSettings() }
    }

    private var newImp: some View {
        HoverIconButton(systemName: "plus", help: "menu.canvas.new_imp", tint: Tone.muted) { actions.newImp() }
    }

    @ViewBuilder private var showHidden: some View {
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
    }

    /// The Devices corner. One mark at a time: a warning when a linked device cannot be reached now,
    /// else a green dot while any is connected.
    private var devices: some View {
        let connected = model.link.connectedPeers.count
        let away = model.link.peers.contains { !$0.isConnected }
        return HoverIconButton(systemName: "laptopcomputer.and.iphone", help: "home.corner.devices", tint: Tone.muted) {
            router.openDevices()
        }
        .overlay(alignment: .topTrailing) {
            if away {
                Image(systemName: "exclamationmark.triangle.fill").font(.icon(.tiny))
                    .foregroundStyle(Tone.warnText)
                    .padding(CornerInset.slack)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if connected > 0 {
                Circle().fill(Tone.good)
                    .frame(width: Spacing.small, height: Spacing.small)
                    .padding(CornerInset.slack)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(away
            ? Text("home.corner.devices.away")
            : connected > 0
                ? Text(verbatim: String.localizedStringWithFormat(NSLocalizedString("home.corner.devices.connected", comment: ""), connected))
                : Text(verbatim: ""))
        .impAnimation(ImpDesign.Motion.fade, value: away ? 2 : connected > 0 ? 1 : 0)
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
