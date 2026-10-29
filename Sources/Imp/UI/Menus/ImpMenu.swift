import AppKit
import ImpKit
import SwiftUI

/// The menu you get by right-clicking an Imp: everything about *that* Imp and nothing else.
/// (App-wide things live in the menu bar menu.)
@MainActor
final class ImpMenu: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let imp: ImpModel
    /// The header button's action, run once the menu has closed (see `StatusMenu.menuDidClose`).
    private var pending: (@MainActor @Sendable () -> Void)?

    init(app: AppModel, imp: ImpModel) {
        self.app = app
        self.imp = imp
    }

    func make() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
        menu.delegate = self
        let name = imp.profile.name
        let header = NSMenuItem()
        header.view = headerView(closing: menu)
        menu.addItem(header)
        menu.addItem(.separator())

        // Right now: only when this Imp has something to stop or grab.
        let result = imp.bubble?.phase == .result ? imp.bubble : nil
        if imp.isBusy { add(menu, String(localized: "Stop"), symbol: "stop.circle", action: #selector(stop)) }
        if result != nil { add(menu, String(localized: "Copy Last Reply"), symbol: "doc.on.doc", action: #selector(copyLast)) }
        add(menu, String(localized: "Chat"), symbol: "bubble.left.and.bubble.right", action: #selector(openChat))
            .toolTip = String(localized: "Everything you and \(name) said, with the tools it used.")
        menu.addItem(.separator())

        // Its triggers that ask it something, to run right now (clicks are right here already).
        let own = app.prefs.shortcuts(of: imp.id).filter { $0.isEnabled && $0.command == .ask && $0.trigger.kind != .clicks }
        if !own.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Triggers")))
            for action in own {
                let mi = add(menu, action.name, symbol: action.trigger.kind == .keys ? action.symbol : action.trigger.kind.symbol,
                             action: #selector(run(_:)))
                mi.representedObject = action.id
                if let key = action.keys, let equivalent = key.keyEquivalent {
                    mi.keyEquivalent = equivalent
                    mi.keyEquivalentModifierMask = key.modifierFlags
                }
            }
            menu.addItem(.separator())
        }

        menu.addItem(submenu(String(localized: "Colour"), symbol: "paintpalette", items: ImpProfile.colors.map { c in
            (c.name, abs(imp.profile.hue - c.hue) < 0.005, NSNumber(value: c.hue), StatusIcon.swatch(hue: c.hue))
        }, action: #selector(setColour(_:))))
        menu.addItem(submenu(String(localized: "Size"), symbol: "arrow.up.left.and.arrow.down.right", items: Panels.sizes.map { title, scale in
            (title, abs(imp.profile.scale - scale) < 0.01, NSNumber(value: scale), nil)
        }, action: #selector(setSize(_:))))
        menu.addItem(.separator())
        add(menu, String(localized: "Send \(name) Home"), symbol: "house", action: #selector(sendHome))
            .toolTip = String(localized: "\(name) goes back into the Imps' window, and its triggers rest.")
        return menu
    }

    // MARK: Building

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return mi
    }

    private func submenu(_ title: String, symbol: String, items: [(String, Bool, NSNumber, NSImage?)], action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu()
        for (name, on, value, image) in items {
            let mi = sub.addItem(withTitle: name, action: action, keyEquivalent: "")
            mi.target = self
            mi.state = on ? .on : .off
            mi.representedObject = value
            mi.image = image
        }
        item.submenu = sub
        return item
    }

    private func headerView(closing menu: NSMenu) -> NSView {
        // Remember what to do, then close the menu. `menuDidClose` does it.
        let run = { [weak self, weak menu] (action: @escaping @MainActor @Sendable () -> Void) in
            self?.pending = action
            menu?.cancelTracking()
        }
        let status = imp.isReady ? String(localized: "Awake") : String(localized: "Needs a brain")
        let header = MenuHeader(
            ready: imp.isReady, name: imp.profile.name, hue: imp.profile.hue, status: status,
            talk: { [weak self] in run { self?.imp.talk() } },
            type: { [weak self] in run { self?.imp.startTyping() } },
            settings: { [weak self] in run { self?.edit() } })
        let host = MenuRowHost(rootView: header)
        host.frame.size = host.fittingSize
        host.autoresizingMask = [.width]
        return host
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let action = pending else { return }
        pending = nil
        DispatchQueue.main.async(execute: action)
    }

    // MARK: Actions

    private var index: Int? { app.prefs.imps.firstIndex { $0.id == imp.id } }

    @objc private func stop() { imp.dismissBubble() }
    @objc private func copyLast() { imp.copyBubble() }
    @objc private func openChat() { imp.openChat() }
    @objc private func setSize(_ sender: NSMenuItem) {
        guard let i = index, let scale = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        app.prefs.imps[i].scale = scale
    }
    @objc private func setColour(_ sender: NSMenuItem) {
        guard let i = index, let hue = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        app.prefs.imps[i].hue = hue
    }
    /// Back into the app's window: flies home if the window is open, else just steps inside.
    @objc private func sendHome() {
        let id = imp.id
        let home = HomeWindow.shared
        if home.isVisible, home.router.selection == id, let slot = home.router.slot(side: Panels.baseSize * imp.profile.scale),
           let fly = app.flyHome {
            fly(id, slot.origin) { [app] in app.setActive(id, false) }
        } else {
            app.setActive(id, false)
            home.show(app, imp: id)
        }
    }
    private func edit() { HomeWindow.shared.show(app, settingsFor: imp.id) }
    @objc private func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let action = app.prefs.shortcuts.first(where: { $0.id == id }) else { return }
        app.trigger(action, trying: true)
    }
}
