import Foundation

/// The words and symbols of the settings map, shared by the Mac and the iPhone. The state is a symbol and a
/// word, never colour alone.
extension AttentionItem {
    public var text: String {
        func said(_ key: String.LocalizationValue, _ arg: String) -> String { String(format: String(localized: key), arg) }
        switch reason {
        case .noBrains: return String(localized: "brains.empty")
        case .noBrain(let imp): return said("settings.attention.imp_no_brain", imp.name)
        case .hopNotSet: return String(localized: "settings.attention.hop_off")
        case .deviceOffline(let name): return said("settings.attention.device_offline", name)
        }
    }

    /// What the problem is about, as a picture: the thing that is missing or away.
    public var symbol: String {
        switch reason {
        case .noBrains, .noBrain: "lightbulb.slash"
        case .hopNotSet: "arrow.triangle.swap"
        case .deviceOffline: "wifi.slash"
        }
    }
}

extension SettingsNode {
    public var title: String {
        switch kind {
        case .thisDevice: String(localized: "settings.map.this_device")
        case .brains: String(localized: "settings.map.brains")
        case .tools: String(localized: "settings.map.tools")
        case .hop: String(localized: isLocal ? "settings.map.hop_local" : "settings.map.hop")
        case .desktop, .phone: name
        }
    }

    public var symbol: String {
        switch kind {
        case .thisDevice, .desktop: "desktopcomputer"
        case .phone: "iphone.gen3"
        case .brains: "brain"
        case .tools: "wrench.and.screwdriver"
        case .hop: "arrow.triangle.swap"
        }
    }

    public var stateWord: String {
        switch state {
        case .ready: String(localized: "settings.map.state_ready")
        case .needsSetup: String(localized: "settings.map.state_needs_setup")
        case .off: String(localized: "settings.map.state_off")
        case .offline: String(localized: "settings.map.state_offline")
        }
    }

    /// A shape as well as a colour, so the state is never colour alone.
    public var stateSymbol: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .needsSetup: "exclamationmark.triangle.fill"
        case .off: "minus.circle"
        case .offline: "wifi.slash"
        }
    }

    /// The lines under the name: the Imps here, and for another device how it is reached.
    public var details: [String] {
        var lines: [String] = []
        if !imps.isEmpty { lines.append(ListFormatter.localizedString(byJoining: imps)) }
        if kind == .desktop || kind == .phone {
            lines.append(String(localized: seen ? "settings.map.seen" : "settings.map.not_seen"))
            if let via { lines.append(String(format: String(localized: "settings.map.via"), via)) }
            if toolsHere { lines.append(String(localized: "settings.map.tools_here")) }
        }
        return lines
    }
}
