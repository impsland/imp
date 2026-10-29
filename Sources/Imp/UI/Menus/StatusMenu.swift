import AppKit
import ImpKit
import SwiftUI

/// The menu bar item: a small panel of buttons (Imps, Hide, Settings, Quit). Everything else lives in the app's window
/// and in each Imp's own right-click menu.
///
/// It's our own non-activating panel (like the speech bubble), not an `NSMenu` with a SwiftUI
/// row: there, Imp never owns the pointer, so the window behind the menu kept reacting to it
/// (its hover effects and cursor showed through the buttons).
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let panel = FloatingPanel(size: CGSize(width: 300, height: 52))
    /// Clicks elsewhere (in other apps, and in Imp's other windows) and Esc close the panel.
    private var monitors: [Any] = []

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.image = StatusIcon.image
        item.button?.toolTip = "Imp"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])   // opens on press, like a menu
        panel.level = .popUpMenu
        panel.allowsKey = true                    // for Esc, ⌘, and ⌘Q (still never activates Imp)
        panel.hasShadow = true
    }

    private var isOpen: Bool { panel.isVisible }

    @objc private func toggle() { isOpen ? close() : open() }

    private func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        panel.appearance = NSApp.appearance       // follow Imp's light/dark setting
        let host = NSHostingView(rootView: bar.padding(.vertical, 5))
        let size = host.fittingSize               // measure first: without sizing options it reports zero
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = Self.background(around: host)

        // Just under the icon, like a menu, and on screen.
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        let x = min(max(icon.minX, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(CGRect(x: x, y: icon.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        keepHighlighted()

        monitors = [
            // Clicks in other apps close it. The icon itself may be drawn by the system (a click on
            // it then looks like one in another app): it's left to the icon, which toggles, or
            // the panel would close here and reopen right away.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.iconFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
                    self.close()
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                let escape = event.type == .keyDown && event.keyCode == 53
                let window = event.window
                let closing = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    // The status button toggles by itself; any other window of ours closes the panel.
                    let elsewhere = event.type != .keyDown && window !== self.panel && window !== self.item.button?.window
                    if escape || elsewhere { self.close() }
                    return escape
                }
                return closing ? nil : event                                    // Esc is ours
            },
        ].compactMap { $0 }
    }

    /// The icon on screen.
    private var iconFrame: CGRect {
        guard let button = item.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Lit while the panel is open, like a menu's title. Pressing the icon lights it, and letting
    /// go turns it off again, so it's lit once the mouse button is up.
    private func keepHighlighted() {
        item.button?.highlight(true)
        Task { [weak self] in
            for _ in 0..<100 where NSEvent.pressedMouseButtons != 0 {         // at most 2 s
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, self.isOpen else { return }
            self.item.button?.highlight(true)
        }
    }

    private func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
        item.button?.highlight(false)
    }

    /// Closes the panel, then does what was asked, still within the click: a window opened here
    /// is then brought forward as the user's own request (see `HomeWindow.bringToFront`).
    private func run(_ action: @MainActor () -> Void) {
        close()
        action()
    }

    private var bar: QuickBar {
        let anyoneOut = !model.imps.isEmpty
        let shown = !model.anyHiding
        return QuickBar(buttons: [
            QuickBar.Item(icon: "house.fill", title: "Imps", help: "Open the Imps' home (⌘,)") { [weak self] in
                guard let self else { return }
                self.run { HomeWindow.shared.reveal(self.model) }
            },
            QuickBar.Item(icon: shown ? "eye.slash.fill" : "eye.fill", title: shown ? "Hide" : "Show",
                          help: anyoneOut ? (shown ? "Hide the Imps on your desktop" : "Show the Imps again")
                                          : "No Imps are out on the desktop",
                          enabled: anyoneOut) { [weak self] in
                guard let self else { return }
                self.run { self.toggleImps() }
            },
            QuickBar.Item(icon: "gearshape.fill", title: "Settings", help: "Settings for all Imps: services, talking, animations, permissions, app") { [weak self] in
                guard let self else { return }
                self.run { HomeWindow.shared.showGeneral(self.model) }
            },
            QuickBar.Item(icon: "power", title: "Quit", help: "Quit Imp (⌘Q)") { [weak self] in
                self?.run { NSApp.terminate(nil) }
            },
        ])
    }

    /// The menu material with rounded corners (the window shadow follows its shape).
    private static func background(around content: NSView) -> NSView {
        let effect = NSVisualEffectView(frame: content.frame)
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    private func toggleImps() { model.setHidden(!model.anyHiding) }
}
