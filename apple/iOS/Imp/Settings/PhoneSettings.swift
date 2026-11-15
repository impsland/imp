import ImpDesign
import ImpKit
import SwiftUI

/// What a person sets on this phone, kept on this phone.
enum PhonePrefs {
    /// Voices an Imp marked to play on their own do so in a new reply.
    static let autoplayKey = "autoplayVoices"
    /// Auto, light or dark.
    static let appearanceKey = "appearance"
    /// White or black on coloured controls.
    static let controlInkKey = "controlInk"
    /// The visiting Imps whose "only talks here" notice was put away.
    static let dismissedWithheldKey = "dismissedWithheldNotices"
}

/// The sections of the phone's settings, always one tap away, each one of the Mac's sections. Animations,
/// Tools and Sharing are not here: they are made, given out and shared in the Den on the Mac, and nothing in
/// them changes what this phone does. Imps hatched here have no Den tools (docs/ux/parity.md).
enum PhoneSection: String, CaseIterable, Identifiable {
    case brains, devices, app
    var id: String { rawValue }

    /// The Mac's section this one is. Its name and what needs attention in it come from there.
    var group: SettingsGroup {
        switch self {
        case .brains: .brains
        case .devices: .devices
        case .app: .app
        }
    }

    var title: String { group.title }

    var symbol: String {
        switch self {
        case .brains: "lightbulb"
        case .devices: "link"
        case .app: "slider.horizontal.3"
        }
    }
}

extension ControlInk {
    /// The stored choice as the design system's value, for `EnvironmentValues.tintInk`.
    var tintInk: TintInk {
        switch self {
        case .white: .white
        case .black: .black
        }
    }

    var title: String {
        switch self {
        case .white: String(localized: "settings.app.control_ink.white")
        case .black: String(localized: "settings.app.control_ink.black")
        }
    }

    /// A letter on a filled disc for white, on an empty one for black.
    var symbol: String {
        switch self {
        case .white: "a.circle.fill"
        case .black: "a.circle"
        }
    }
}

extension Appearance {
    var title: String {
        switch self {
        case .system: String(localized: "phone.appearance.auto")
        case .light: String(localized: "phone.appearance.light")
        case .dark: String(localized: "phone.appearance.dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the person's choices of light or dark, and of white or black on coloured controls, at the
/// root of the app and of every sheet.
private struct PhoneAppearance: ViewModifier {
    @AppStorage(PhonePrefs.appearanceKey) private var appearance: Appearance = .system
    @AppStorage(PhonePrefs.controlInkKey) private var controlInk: ControlInk = .white
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme).environment(\.tintInk, controlInk.tintInk)
    }
}

extension View {
    func phoneAppearance() -> some View { modifier(PhoneAppearance()) }
}
