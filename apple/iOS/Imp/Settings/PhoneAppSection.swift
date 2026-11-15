import ImpDesign
import ImpKit
import SwiftUI

/// The App section: how the app looks and speaks (appearance, controls, language, voices), haptics, the shake, and the version.
struct PhoneAppSection: View {
    @AppStorage(PhonePrefs.appearanceKey) private var appearance: Appearance = .system
    @AppStorage(PhonePrefs.autoplayKey) private var autoplay = true
    @AppStorage(PhonePrefs.controlInkKey) private var controlInk: ControlInk = .white
    @AppStorage(Haptics.enabledKey) private var haptics = true

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Card("app.look", icon: "paintbrush.fill", info: "settings.app.look.info") {
                Row("settings.app.appearance.title", icon: "circle.lefthalf.filled") {
                    ImpSegmented("settings.app.appearance.title", selection: $appearance, options: Appearance.allCases,
                                 title: { $0.title }, symbol: { $0.symbol })
                }
                Row("settings.app.control_ink.title", icon: "textformat", info: "settings.app.control_ink.info") {
                    ImpSegmented("settings.app.control_ink.title", selection: $controlInk, options: ControlInk.allCases,
                                 title: { $0.title }, symbol: { $0.symbol })
                }
            }
            Card("phone.app.speech", icon: "text.bubble.fill") {
                PhoneLanguageRow()
                Row("voice.autoplay", icon: "play.circle.fill") {
                    Toggle("voice.autoplay", isOn: $autoplay).toggleStyle(.impSwitchBare)
                }
            }
            Card("phone.haptics.title", icon: "hand.tap.fill", info: "phone.haptics.info", accessory: {
                Toggle("phone.haptics.title", isOn: $haptics).toggleStyle(.impSwitchBare)
                    .accessibilityIdentifier("app.haptics")
            }) { EmptyView() }
            ShakeSettingsCard()
            Card("phone.about.title", icon: "info.circle") {
                Row("phone.version", icon: "number") {
                    Text(verbatim: version).font(Typeface.body).foregroundStyle(Tone.muted)
                }
            }
        }
    }
}

/// The language Imp's text is in: the iPhone's, or one just for Imp. Kept where iOS keeps the language of an app
/// (`AppLanguage`, the same as Settings › Apps › Imp › Language), so the two always agree. iOS reads it when the
/// app opens, so a note says when the pick shows.
struct PhoneLanguageRow: View {
    /// What's picked (nil: the iPhone's), read from Imp's own defaults.
    @State private var chosen: String? = PhoneLanguageRow.read()
    /// What was picked when Imp opened: what it shows now.
    private static let atLaunch = PhoneLanguageRow.read()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Row("app.language", icon: "globe") {
                ImpPicker("app.language", selection: Binding(get: { chosen ?? "" }, set: { pick($0.isEmpty ? nil : $0) }),
                          options: [""] + AppLanguage.supported) { code in
                    code.isEmpty ? String(localized: "phone.language.system") : AppLanguage.name(code)
                }
                .accessibilityIdentifier("app.language")
            }
            if chosen != Self.atLaunch {
                StatusText(text: "phone.language.next_open", symbol: "arrow.clockwise.circle.fill", color: Tone.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pick(_ code: String?) {
        AppLanguage.choose(code, in: .standard)
        chosen = Self.read()
    }

    private static func read() -> String? {
        AppLanguage.chosen(in: Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) })
    }
}
