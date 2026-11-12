import ImpDesign
import ImpKit
import SwiftUI

/// The App section: how the app looks, what a double tap does, the voices, the shake and the version.
struct PhoneAppSection: View {
    @AppStorage(PhonePrefs.appearanceKey) private var appearance: Appearance = .system
    @AppStorage(PhonePrefs.doubleTapKey) private var doubleTap: DoubleClickAction = .openSettings
    @AppStorage(PhonePrefs.autoplayKey) private var autoplay = true
    @AppStorage(PhonePrefs.controlInkKey) private var controlInk: ControlInk = .white
    @Environment(\.openURL) private var openURL

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
            Card("app.behaviour", icon: "slider.horizontal.3", info: "settings.app.behaviour.info") {
                Row("pref.double_click.title_touch", icon: "cursorarrow.click.2") {
                    ImpPicker("pref.double_click.title_touch", selection: $doubleTap, options: DoubleClickAction.allCases,
                              title: { String(localized: $0.title) })
                }
                Row("voice.autoplay", icon: "play.circle.fill") {
                    Toggle("voice.autoplay", isOn: $autoplay).toggleStyle(.impSwitchBare)
                }
                Row("app.language", icon: "globe") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { FitLabel("common.open", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.secondary)
                }
            }
            ShakeSettingsCard()
            Card("phone.about.title", icon: "info.circle") {
                Row("phone.version", icon: "number") {
                    Text(verbatim: version).font(Typeface.body).foregroundStyle(Tone.muted)
                }
            }
        }
    }
}
