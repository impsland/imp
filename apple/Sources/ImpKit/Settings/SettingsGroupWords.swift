import Foundation

/// The name and symbol of each section of the All Imps settings, shared by the Mac and the iPhone.
extension SettingsGroup {
    public var title: String {
        switch self {
        case .app: String(localized: "settings.group.app")
        case .bubble: String(localized: "settings.group.bubble")
        case .talking: String(localized: "settings.group.talking")
        case .brains: String(localized: "settings.group.brains")
        case .devices: String(localized: "settings.group.devices")
        case .sharing: String(localized: "settings.group.sharing")
        case .animations: String(localized: "settings.group.animations")
        case .privacy: String(localized: "settings.group.privacy")
        case .backup: String(localized: "settings.group.backup")
        }
    }

    public var symbol: String {
        switch self {
        case .app: "gearshape.fill"
        case .bubble: "text.bubble.fill"
        case .talking: "bubble.left.and.bubble.right.fill"
        case .brains: "brain.head.profile"
        case .devices: "laptopcomputer.and.iphone"
        case .sharing: "tray.full.fill"
        case .animations: "sparkles"
        case .privacy: "lock.shield.fill"
        case .backup: "shippingbox.fill"
        }
    }
}
