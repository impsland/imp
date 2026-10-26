import Carbon.HIToolbox
import ImpKit
import os

/// Global shortcuts via Carbon `RegisterEventHotKey` — no Accessibility or Input
/// Monitoring permission needed, and the key press is consumed (doesn't leak to apps).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onPress: ((Hotkey) -> Void)?
    private(set) var failed: Set<Hotkey> = []

    private var registered: [UInt32: (Hotkey, EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?
    private var desired: [Hotkey] = []
    private var suspended = false
    private let log = Logger(subsystem: "app.imp.Imp", category: "hotkeys")

    private init() {}

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let id = hk.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Replaces all registrations. Returns the shortcuts the system refused (already taken).
    @discardableResult
    func register(_ hotkeys: [Hotkey]) -> Set<Hotkey> {
        desired = Array(Set(hotkeys))
        if !suspended { apply() }
        return failed
    }

    /// Temporarily releases all shortcuts (while recording a new one in Settings).
    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; apply() }

    private func apply() {
        unregisterAll()
        failed = []
        var nextID: UInt32 = 1
        for key in desired {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x494D5021) /* 'IMP!' */, id: nextID)
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[nextID] = (key, ref)
            } else {
                failed.insert(key)
                log.error("Could not register \(key.displayString, privacy: .public): \(status)")
            }
            nextID += 1
        }
    }

    private func unregisterAll() {
        for (_, (_, ref)) in registered { UnregisterEventHotKey(ref) }
        registered = [:]
    }

    private func fire(_ id: UInt32) {
        guard let (key, _) = registered[id] else { return }
        onPress?(key)
    }
}
