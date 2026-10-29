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
            router.selection = (model.focused?.profile ?? model.prefs.imps[0]).id
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
            window = w
        }
        SystemStatus.shared.start()
        if let window { bringToFront(window) }
    }

    /// Opens the window in front of everything. While the window is open, Imp is a regular app
    /// (in the Dock and the ⌘-Tab switcher). Since macOS 14 activation is cooperative: the system
    /// grants it for a request made while handling the user's click or key press, so callers run
    /// this synchronously from that event, never deferred to a later turn of the run loop.
    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
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
    var impTab: ImpTab = .me
    var generalTab: GeneralTab = .brains
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

    func select(_ imp: UUID) { selection = imp }

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
    case me, brain, tools, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .me: "Looks"
        case .brain: "Brain"
        case .tools: "Tools"
        case .shortcuts: "Triggers"
        }
    }

    var icon: String {
        switch self {
        case .me: "paintpalette.fill"
        case .brain: "brain.head.profile"
        case .tools: "wrench.and.screwdriver.fill"
        case .shortcuts: "bolt.fill"
        }
    }
}

/// Settings every Imp shares.
enum GeneralTab: String, CaseIterable, Identifiable {
    case brains, manners, animations, hearing, permissions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brains: "Brain keys"
        case .manners: "Manners"
        case .animations: "Animations"
        case .hearing: "Hearing"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .brains: "key.fill"
        case .manners: "hand.wave.fill"
        case .animations: "sparkles"
        case .hearing: "ear.fill"
        case .permissions: "lock.shield.fill"
        }
    }
}
