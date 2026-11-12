import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// How the app looks and behaves.
struct AppPane: View {
    @Bindable var model: AppModel
    let router: HomeRouter
    @State private var loginError: String?
    private var actions: HomeActions { HomeActions(model: model, router: router) }
    private var status: SystemStatus { .shared }
    private var kind: CanvasBackground.Kind { model.prefs.background.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("app.look", icon: "paintbrush.fill", info: "settings.app.look.info") {
                Row("settings.app.appearance.title", icon: "circle.lefthalf.filled") {
                    ImpSegmented("settings.app.appearance.title", selection: $model.prefs.appearance,
                                 options: [Appearance.system, .light, .dark], title: { appearance in
                        switch appearance {
                        case .system: String(localized: "Auto")
                        case .light: String(localized: "Light")
                        case .dark: String(localized: "Dark")
                        }
                    }, symbol: { appearance in
                        switch appearance {
                        case .system: "circle.lefthalf.filled"
                        case .light: "sun.max.fill"
                        case .dark: "moon.fill"
                        }
                    })
                }
                .settingAnchor(.appAppearance)
                Row("settings.app.control_ink.title", icon: "textformat", info: "settings.app.control_ink.info") {
                    ImpSegmented("settings.app.control_ink.title", selection: $model.prefs.controlInk,
                                 options: ControlInk.allCases, title: { String(localized: $0.title) }, symbol: { $0.symbol })
                }
                .settingAnchor(.appControlInk)
                background
            }

            Card("app.behaviour", icon: "slider.horizontal.3", info: "settings.app.behaviour.info") {
                Row("pref.double_click.title", icon: "cursorarrow.click.2") {
                    ImpPicker("pref.double_click.title", selection: $model.prefs.doubleClick,
                              options: DoubleClickAction.allCases, symbol: model.prefs.doubleClick.symbol) { $0.title }
                }
                .settingAnchor(.appDoubleClick)
                Row("app.login", icon: "power") {
                    Toggle(String(""), isOn: Binding(
                        get: { status.launchesAtLogin },
                        set: { on in
                            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                            status.refresh()
                        })).labelsHidden().toggleStyle(.impSwitchBare)
                }
                .settingAnchor(.appLogin)
                if let loginError { StatusText(verbatim: loginError, symbol: "exclamationmark.triangle.fill", color: Tone.danger).help(loginError) }
                LanguageRow(model: model)
            }

            Card("app.window.title", icon: "macwindow", info: "app.window.info") {
                Row("app.window.min_width", icon: "arrow.left.and.right") { windowSlider(\.width, in: WindowSizing.widths, label: "app.window.min_width") }
                    .settingAnchor(.appWindowWidth)
                Row("app.window.min_height", icon: "arrow.up.and.down") { windowSlider(\.height, in: WindowSizing.heights, label: "app.window.min_height") }
                    .settingAnchor(.appWindowHeight)
            }
        }
        .impAnimation(ImpDesign.Motion.expand, value: kind)
    }

    /// One side of the smallest window, in points (a double click goes back to the default).
    private func windowSlider(_ side: WritableKeyPath<CGSize, CGFloat>, in range: ClosedRange<Double>, label: LocalizedStringKey) -> some View {
        let value = Binding<Double>(get: { Double(model.prefs.windowMinimum[keyPath: side]) },
                                    set: { var size = model.prefs.windowMinimum; size[keyPath: side] = CGFloat($0); model.prefs.windowMinimum = size })
        return RowSlider(value: value, range: range, step: WindowSizing.step, label: label,
                         shown: words("app.window.points", Int(value.wrappedValue)), resets: Double(WindowSizing.defaultMinimum[keyPath: side]))
    }

    /// The choice on one row; below it, only when the kind needs it, the action that finishes it.
    @ViewBuilder private var background: some View {
        Row("menu.canvas.background", icon: "photo.fill") {
            ImpSegmented("menu.canvas.background", selection: Binding(get: { kind }, set: { actions.setBackground($0) }),
                         options: BackgroundGroup.kinds, title: BackgroundGroup.title, symbol: BackgroundGroup.symbol)
        }
        .settingAnchor(.appBackground)
        if let follow = BackgroundGroup.follow(kind) {
            HStack(spacing: Spacing.small) {
                Spacer(minLength: Spacing.medium)
                switch follow {
                case .colour:
                    Circle().fill(Color(.sRGB, red: model.prefs.background.colour.red, green: model.prefs.background.colour.green,
                                        blue: model.prefs.background.colour.blue))
                        .frame(width: Sizing.iconTile, height: Sizing.iconTile)
                        .accessibilityHidden(true)
                    Button { actions.chooseColour() } label: { FitLabel("background.choose_colour", systemImage: "paintpalette") }
                        .buttonStyle(.imp(.secondary, small: true))
                case .picture:
                    Button { actions.choosePicture() } label: { FitLabel("background.choose_picture", systemImage: "photo") }
                        .buttonStyle(.imp(.secondary, small: true))
                }
            }
            .frame(minHeight: Sizing.hit)
            .transition(.opacity)
        }
    }
}


/// The language Imp's text is in: the Mac's, or one just for Imp (the same setting as System
/// Settings › General › Language & Region › Applications). It applies once Imp restarts, so a
/// Restart Now button shows while what's picked isn't what's showing.
struct LanguageRow: View {
    let model: AppModel
    /// What's picked (nil: the Mac's), read from Imp's own defaults.
    @State private var chosen: String? = LanguageRow.read()
    /// The language this run of Imp shows.
    private static let running = Bundle.main.preferredLocalizations.first ?? "en"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Row("app.language", icon: "globe") {
                ImpPicker("app.language", selection: Binding(get: { chosen ?? "" }, set: { pick($0.isEmpty ? nil : $0) }),
                          options: [""] + AppLanguage.supported) { code in
                    code.isEmpty ? String(localized: "Same as my Mac") : AppLanguage.name(code)
                }
            }
            .settingAnchor(.appLanguage)
            if needsRestart {
                HStack(spacing: Spacing.small) {
                    StatusText(text: "Imp switches language when it restarts.", symbol: "arrow.clockwise.circle.fill", color: Tone.accent)
                    Spacer(minLength: Spacing.small)
                    Button { model.relaunch() } label: { FitLabel("Restart Now", systemImage: "arrow.clockwise") }
                        .buttonStyle(.imp(.primary, small: true))
                        .help("Quit Imp and open it again. Imps out on your desktop come back where they were.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            chosen = Self.read()          // changed in System Settings meanwhile
        }
    }

    /// What Imp would show after a restart differs from what it shows now.
    private var needsRestart: Bool {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
        return AppLanguage.resolved(chosen: chosen, system: system) != Self.running
    }

    private func pick(_ code: String?) {
        AppLanguage.choose(code, in: .standard)
        chosen = Self.read()
    }

    private static func read() -> String? {
        AppLanguage.chosen(in: Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) })
    }
}
