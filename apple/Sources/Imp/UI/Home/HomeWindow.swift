import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The app's window: the Imps' home. Imps that aren't activated wait here. Settings open inside it.
@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    private(set) var window: NSWindow?
    let router = HomeRouter()

    var isVisible: Bool { window?.isVisible == true }

    /// Whether a point on screen is over the home screen, where a free Imp can be dropped to go home. Only when that
    /// window is showing there, not covered by another app's window.
    func isOver(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized, router.screen == .home else { return false }
        guard window.frame.contains(point), window.occlusionState.contains(.visible) else { return false }
        // The window must be the one showing at that point: not hidden behind another app's windows.
        // The Imps' own panels float above it, so they don't count.
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        while number > 0, number != window.windowNumber {
            guard let other = NSApp.window(withWindowNumber: number), other is NSPanel else { return false }
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: number)
        }
        return number == window.windowNumber
    }

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

    /// Opens an Imp's settings (optionally on one panel).
    func show(_ model: AppModel, settingsFor imp: UUID, panel: ImpSetting? = nil) {
        router.select(imp)
        router.openSettings(imp, panel: panel)
        open(model)
    }

    /// Opens the first run for an Imp that has no Brain: the sheet comes up over what's showing. It is
    /// remembered that the path was shown, so it never comes up by itself again.
    func showFirstRun(_ model: AppModel, imp: UUID) {
        model.prefs.firstRunSeen = true
        reveal(model)
        router.firstRun = imp
    }

    /// Opens the exact page of a setting, app-wide or an Imp's, and lights the setting up.
    func show(_ model: AppModel, target: SettingsTarget, imp: UUID) {
        router.open(target: target, imp: imp)
        open(model)
    }

    /// Opens the app-wide settings on the section that was showing last (optionally on one section).
    func showGeneral(_ model: AppModel, group: SettingsGroup? = nil) {
        if let group { router.settingsSection = group }
        router.screen = .general
        open(model)
    }

    /// Opens the window on a kit to add, wherever it was: the review sheet comes up over what's showing.
    func showKit(_ model: AppModel, _ flow: KitFlow) {
        reveal(model)
        router.kitFlow = flow
    }

    /// Opens the window on a talk between two Imps: it comes up as a sheet over what's showing.
    func showTalk(_ model: AppModel, imp: UUID, peer: UUID) {
        reveal(model)
        router.talk = TalkRequest(imp: imp, peer: peer)
    }

    /// Opens a chat with you to read, as bubbles or as JSON.
    func showChat(_ model: AppModel, imp: UUID, chat: UUID) {
        reveal(model)
        router.talk = TalkRequest(imp: imp, peer: imp, chat: chat)
    }

    /// The smallest size changed in Settings: the window takes it, and grows if it is now smaller.
    func applyMinimum(_ minimum: CGSize) {
        guard let window else { return }
        window.contentMinSize = minimum
        let current = window.contentLayoutRect.size
        let fitted = WindowSizing.fitted(current, minimum: minimum)
        if fitted != current { window.setContentSize(fitted) }
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
            w.title = "Imp"                                    // for the window list: the bar shows no text
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.titlebarSeparatorStyle = .none
            w.backgroundColor = NSColor(Tone.surface)           // the window follows the Appearance preference
            // The smallest size is the person's setting; after the first opening it keeps the size it was given.
            w.contentMinSize = model.prefs.windowMinimum
            w.setContentSize(WindowSizing.opening(minimum: model.prefs.windowMinimum))
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
                    let seen = w?.occlusionState.contains(.visible) ?? false
                    HomeWindow.shared.router.isAwake = seen
                    // Nobody looks at the window, so the permissions it shows need no re-reading every 2 s.
                    if seen { SystemStatus.shared.start() } else { SystemStatus.shared.stop() }
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
    /// The Imp that has the keyboard on the canvas. The menu bar's Imp menu acts on it.
    var selection: UUID?
    /// The panel an Imp's settings should open on: the page takes it when it shows.
    var impPanel: ImpSetting?
    /// The setting that is lit for a moment after something opened it. The page scrolls to it.
    var highlightedSetting: SettingID?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    /// The section of the app-wide settings that is chosen in the rail. It is kept while the app runs,
    /// so Settings opens where the person left it.
    var settingsSection: SettingsGroup = .app
    /// The canvas's view, to find where things on it are on screen. (Not observed: the window moves
    /// without SwiftUI knowing, so positions are worked out when they're needed, never stored.)
    @ObservationIgnored weak var canvasAnchor: NSView?
    /// Where each Imp stands on the canvas: its centre, as a fraction of the canvas's width and height.
    /// Kept while the app runs.
    var places: [UUID: CGPoint] = [:]
    /// Imps that just arrived (hatched, imported, or from a link): they pop in once.
    private(set) var arriving: Set<UUID> = []
    /// An Imp the user chose Goodbye for: the window asks before it goes.
    var saying: UUID?
    /// A borrowed tool whose form should open (an Imp asked the user to fill in its keys).
    var serverToEdit: UUID?
    /// A kit being added (the text box, then the review). Nothing is applied until its Add.
    var kitFlow: KitFlow? { didSet { if oldValue !== kitFlow { oldValue?.abandon() } } }
    /// A talk between two Imps being read (a sheet).
    var talk: TalkRequest?
    /// A picture that could not be used as the background: the window says so.
    var pictureFailed = false
    /// The Imp being woken up by the first run (a sheet).
    var firstRun: UUID?

    /// Whether the window can be seen at all. Nothing animates while it can't.
    var isAwake = true

    /// The canvas on screen (points, y up), found when asked: the window moves without SwiftUI knowing.
    var canvasOnScreen: CGRect? {
        guard let view = canvasAnchor, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Where the Imp `id` (`side` points square) is drawn on screen right now, so letting it out
    /// doesn't move it a single point and it can fly back to the same place. Nil when the canvas isn't showing.
    func slot(of id: UUID, side: CGFloat) -> CGRect? {
        guard screen == .home, let place = places[id], let canvas = canvasOnScreen else { return nil }
        let centre = CanvasLayout.point(of: place, in: canvas.size, figure: side)
        return CanvasLayout.screenFrame(centre: centre, figure: side, canvas: canvas)
    }

    /// The place on the canvas under a point on screen, for an Imp `side` points square.
    func place(atScreen point: CGPoint, side: CGFloat) -> CGPoint? {
        guard let canvas = canvasOnScreen else { return nil }
        return CanvasLayout.place(at: CanvasLayout.canvasPoint(point, canvas: canvas), in: canvas.size, figure: side)
    }

    func select(_ imp: UUID) { selection = imp }

    // MARK: Undo

    /// The change the Undo bar offers to take back, for `Behavior.undoBarSeconds`.
    private(set) var undo: UndoOffer?
    @ObservationIgnored private var revert: (@MainActor () -> Void)?

    func offer(_ offer: UndoOffer, revert: @escaping @MainActor () -> Void) {
        undo = offer
        self.revert = revert
    }

    /// Takes the offered change back.
    func undoOffered() {
        let revert = revert
        dismissUndo()
        revert?()
    }

    func dismissUndo() {
        undo = nil
        revert = nil
    }

    /// New Imps (a hatched one, an imported one, one from a link) pop onto the canvas. They must
    /// already be in the model. `next` runs at once.
    func hatch(_ ids: [UUID], then next: (@MainActor () -> Void)? = nil) {
        arriving.formUnion(ids)
        selection = ids.last ?? selection
        goHome()
        next?()
    }

    /// An Imp has finished popping in.
    func arrived(_ id: UUID) { arriving.remove(id) }

    func openSettings(_ imp: UUID, panel: ImpSetting? = nil) {
        if let panel { impPanel = panel }
        withAnimation(ImpDesign.Motion.scene.reducedAware(HomeActions.reduceMotion)) { screen = .imp(imp) }
    }

    /// Opens the page of a setting (an Imp's page for one of its own) and lights the setting up for a moment.
    func open(setting: SettingID, imp: UUID?) {
        open(target: SettingsTarget(setting: setting), imp: imp)
    }

    func open(target: SettingsTarget, imp: UUID?) {
        if let group = target.page.group {
            open(group: group)
        } else if let imp, let panel = ImpSetting(rawValue: target.page.rawValue) {
            select(imp)
            openSettings(imp, panel: panel)
        }
        highlightTask?.cancel()
        highlightedSetting = target.setting
        guard target.setting != nil else { return }
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SettingsTarget.highlightSeconds))
            guard !Task.isCancelled else { return }
            self?.highlightedSetting = nil
        }
    }

    /// Opens the page of one group of the app-wide settings (a map node or an attention item).
    func open(group: SettingsGroup) {
        settingsSection = group
        withAnimation(ImpDesign.Motion.scene.reducedAware(HomeActions.reduceMotion)) { screen = .general }
    }

    func openGeneralSettings() {
        withAnimation(ImpDesign.Motion.scene.reducedAware(HomeActions.reduceMotion)) { screen = .general }
    }

    func goHome() {
        withAnimation(ImpDesign.Motion.scene.reducedAware(HomeActions.reduceMotion)) { screen = .home }
    }
}
