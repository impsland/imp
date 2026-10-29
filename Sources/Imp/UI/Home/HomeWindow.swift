import AppKit
import ImpKit
import SwiftUI

/// The app's window: the Imps' home. Imps that aren't activated wait here. Settings open inside it.
@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    private(set) var window: NSWindow?
    let router = HomeRouter()

    var isVisible: Bool { window?.isVisible == true }

    /// Brings the window back exactly as it was (screen, tab, an open form), or opens it on the
    /// home screen if it was closed. For coming back to the app (Dock click, the Imps button), not
    /// for going somewhere in it.
    func reveal(_ model: AppModel) {
        guard let window else { return show(model) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        bringToFront(window)
    }

    /// Opens the window on the home screen (optionally showing one Imp).
    func show(_ model: AppModel, imp: UUID? = nil) {
        if let imp { router.select(imp) }
        router.screen = .home
        open(model)
    }

    /// Opens an Imp's settings (optionally on a tab).
    func show(_ model: AppModel, settingsFor imp: UUID, tab: ImpTab? = nil) {
        router.select(imp)
        router.openSettings(imp, tab: tab)
        open(model)
    }

    /// Opens the app-wide settings (optionally on a tab).
    func showGeneral(_ model: AppModel, tab: GeneralTab? = nil) {
        if let tab { router.generalTab = tab }
        router.screen = .general
        open(model)
    }

    /// Opens the window on a kit to add, wherever it was: the review sheet comes up over what's showing.
    func showKit(_ model: AppModel, _ flow: KitFlow) {
        reveal(model)
        router.kitFlow = flow
    }

    private func open(_ model: AppModel) {
        if router.selection.flatMap(model.profile) == nil {
            let shown = model.prefs.imps.filter { !router.unhatched.contains($0.id) }
            router.selection = (model.focused?.profile ?? shown.first ?? model.prefs.imps[0]).id
        }
        if window == nil {
            let host = NSHostingController(rootView: HomeView(model: model, router: router))
            // Screens don't resize the window as you move between them.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Imp"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.appearance = NSAppearance(named: .darkAqua)       // the dungeon is always cosy and dark
            w.backgroundColor = NSColor(Dungeon.deep)
            w.setContentSize(NSSize(width: 780, height: 600))
            w.minSize = NSSize(width: 660, height: 540)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ImpHome")
            if !w.setFrameUsingName("ImpHome") { w.center() }
            // Closed means gone: drop the views so nothing keeps animating in a hidden window, and
            // leave the Dock (Imp lives in the menu bar). Activated Imps don't care: they live on the desktop.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    SystemStatus.shared.stop()
                    NSApp.setActivationPolicy(.accessory)
                }
                Task { @MainActor in HomeWindow.shared.window = nil }
            }
            // Hidden behind other windows or minimised: the stage stops animating.
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated {
                    HomeWindow.shared.router.isAwake = w?.occlusionState.contains(.visible) ?? false
                }
            }
            window = w
        }
        SystemStatus.shared.start()
        if let window { bringToFront(window) }
    }

    /// Opens the window in front of everything. While the window is open, Imp is a regular app
    /// (in the Dock and the ⌘-Tab switcher).
    ///
    /// Why it used to open behind other windows: since macOS 14 activation is cooperative, and the
    /// system only lets an app come forward when the request comes from the user's own click or key
    /// press *in that app*. Imp's menu bar panel, its Imps and their bubbles are non-activating
    /// panels (so typing elsewhere is never interrupted), several callers act a moment after the
    /// click (a double-click is only known once the click burst is over, ~0.3 s later; the Imp's menu
    /// runs its header buttons once the menu has closed), and switching from accessory to regular
    /// takes effect a run-loop turn later. Any of these made `activate()` a no-op, and
    /// `makeKeyAndOrderFront` then only ordered the window to the front of *Imp's* windows, behind
    /// the app you were in. So: order it front regardless of activation, pull it onto the Space
    /// you're on, and ask again once the policy change has landed.
    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate()
        let front = window.attachedSheet ?? window
        front.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()                     // above other apps' windows even if activation was declined
        guard !NSApp.isActive else { return }
        Task { @MainActor in
            await Task.yield()                            // the switch to a regular app has taken effect
            guard window.isVisible, !NSApp.isActive else { return }
            NSApp.activate()
            window.orderFrontRegardless()
            (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
        }
    }
}

/// Where the window is and what it shows.
@MainActor @Observable
final class HomeRouter {
    enum Screen: Equatable {
        case home
        case imp(UUID)
        case general
    }

    var screen: Screen = .home
    /// The Imp in the middle of the stage (`nil` = the egg for a new one).
    var selection: UUID?
    var impTab: ImpTab = .looks
    var generalTab: GeneralTab = .services
    /// The stage's view, to find where things on it are on screen. (Not observed: the window moves
    /// without SwiftUI knowing, so positions are worked out when they're needed, never stored.)
    @ObservationIgnored weak var stageAnchor: NSView?

    /// Where the selected Imp (`side` points square) is drawn on screen right now, so activating it
    /// doesn't move it a single point and it can follow the cursor. Nil when the stage isn't showing.
    func slot(side: CGFloat) -> CGRect? {
        guard screen == .home, let view = stageAnchor, let window = view.window, window.isVisible else { return nil }
        let stage = window.convertToScreen(view.convert(view.bounds, to: nil))
        let r = ImpStage.figureRect(stage: stage.size, side: side)
        // Stage coordinates run top-down. The screen's bottom-up.
        return CGRect(x: stage.minX + r.minX, y: stage.maxY - r.maxY, width: r.width, height: r.height)
    }
    /// Set to start renaming the selected Imp on the stage.
    var renaming = false
    /// A borrowed tool whose form should open (an Imp asked the user to fill in its keys).
    var serverToEdit: UUID?
    /// A kit being added (the text box, then the review). Nothing is applied until its Add.
    var kitFlow: KitFlow?

    /// Whether the window can be seen at all. Nothing animates while it can't.
    var isAwake = true
    /// Imps that exist but are still in their eggs, in the order they hatch. The stage keeps them
    /// out of the line until their egg has cracked (see `hatch`).
    private(set) var unhatched: [UUID] = []
    /// Bumped on every `hatch`, so the stage knows there is something to play.
    private(set) var hatchRequests = 0
    /// What to do once the last egg has hatched (an imported tool's form, waiting for its keys).
    @ObservationIgnored private(set) var afterHatching: (@MainActor () -> Void)?

    func select(_ imp: UUID) { selection = imp }

    /// Shows the egg and hatches these Imps one after another (a new one, an imported one, one from
    /// a link). They must already be in the model: they stay out of the line until each one has
    /// stepped out of its egg. `then` runs once they all have (at once if there's nothing to hatch).
    func hatch(_ ids: [UUID], then next: (@MainActor () -> Void)? = nil) {
        let fresh = ids.filter { !unhatched.contains($0) }
        guard !fresh.isEmpty else { next?(); return }
        afterHatching = next
        unhatched += fresh
        hatchRequests += 1
        renaming = false
        selection = nil
        goHome()
    }

    /// An Imp has stepped out of its egg.
    func hatched(_ id: UUID) { unhatched.removeAll { $0 == id } }

    /// Stops waiting for the eggs: whoever is left joins the line as it is.
    func hatchedAll() { unhatched = [] }

    /// The last egg has hatched: runs what was waiting for it.
    func finishHatching() {
        let next = afterHatching
        afterHatching = nil
        next?()
    }

    func openSettings(_ imp: UUID, tab: ImpTab? = nil) {
        if let tab { impTab = tab }
        withAnimation(.snappy(duration: 0.28)) { screen = .imp(imp) }
    }

    func goHome() {
        withAnimation(.snappy(duration: 0.28)) { screen = .home }
    }
}

/// The parts of an Imp's settings.
enum ImpTab: String, CaseIterable, Identifiable {
    case looks, moves, brain, tools, triggers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .looks: String(localized: "Looks")
        case .moves: String(localized: "Moves")
        case .brain: String(localized: "Brain")
        case .tools: String(localized: "Tools")
        case .triggers: String(localized: "Triggers")
        }
    }

    var icon: String {
        switch self {
        case .looks: "paintpalette.fill"
        case .moves: "figure.dance"
        case .brain: "brain.head.profile"
        case .tools: "wrench.and.screwdriver.fill"
        case .triggers: "bolt.fill"
        }
    }
}

/// Settings every Imp shares.
enum GeneralTab: String, CaseIterable, Identifiable {
    case services, talking, animations, permissions, app
    var id: String { rawValue }

    var title: String {
        switch self {
        case .services: String(localized: "Services")
        case .talking: String(localized: "Talking")
        case .animations: String(localized: "Animations")
        case .permissions: String(localized: "Permissions")
        case .app: String(localized: "App")
        }
    }

    var icon: String {
        switch self {
        case .services: "server.rack"
        case .talking: "bubble.left.and.bubble.right.fill"
        case .animations: "sparkles"
        case .permissions: "lock.shield.fill"
        case .app: "gearshape.fill"
        }
    }
}
