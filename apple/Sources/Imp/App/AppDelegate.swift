import AppKit
import ImpKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windows: TroupeWindows?
    private var impMenu: ImpMenu?
    private var sigterm: DispatchSourceSignal?
    private let log = Logger(subsystem: "app.imp.Imp", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` and logout send SIGTERM: quit properly, so tool servers are shut down with it.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source

        let windows = TroupeWindows(app: model)
        // Right-clicking an Imp shows that Imp's own menu.
        windows.menuProvider = { [weak self] imp in
            guard let self else { return NSMenu() }
            let menu = ImpMenu(app: self.model, imp: imp)
            self.impMenu = menu                 // NSMenuItem targets are weak: keep it alive while open
            return menu.make()
        }
        self.windows = windows
        model.start()
        // With nobody out on the desktop, say hello from the app's window.
        if model.imps.isEmpty { HomeWindow.shared.show(model) }
        // A new user with no Brain: the Imp is asleep, and the first run offers to wake it.
        if !model.prefs.firstRunSeen, !model.isReady { HomeWindow.shared.showFirstRun(model, imp: model.prefs.imps[0].id) }
        log.info("Imp is awake")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.link.stop()
        model.flushSave()
        // Chats are written in the background: let the last saves and deletes land.
        ChatHistory.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HomeWindow.shared.reveal(model)
        return false
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let command = URLCommand(string) else { return }
        log.info("URL command: \(String(describing: command), privacy: .public)")
        command.perform(on: model)
    }
}
