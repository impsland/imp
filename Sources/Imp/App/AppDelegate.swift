import AppKit
import ImpKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windows: TroupeWindows?
    private var statusMenu: StatusMenu?
    private var impMenu: ImpMenu?
    private var sigterm: DispatchSourceSignal?
    private let log = Logger(subsystem: "app.imp.Imp", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        let menu = StatusMenu(model: model)
        // Right-clicking an Imp shows that Imp's own menu.
        windows.menuProvider = { [weak self] imp in
            guard let self else { return NSMenu() }
            let menu = ImpMenu(app: self.model, imp: imp)
            self.impMenu = menu                 // NSMenuItem targets are weak: keep it alive while open
            return menu.make()
        }
        self.windows = windows
        statusMenu = menu
        MainMenu.install(openHome: #selector(openHome), target: self)
        model.start()
        // With nobody out on the desktop, say hello from the app's window.
        if model.imps.isEmpty { HomeWindow.shared.show(model) }
        log.info("Imp is awake")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Chats are written in the background: let the last saves and deletes land.
        ChatHistory.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HomeWindow.shared.reveal(model)
        return false
    }

    @objc private func openHome() { HomeWindow.shared.show(model) }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let command = URLCommand(string) else { return }
        log.info("URL command: \(String(describing: command), privacy: .public)")
        command.perform(on: model)
    }
}
