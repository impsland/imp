import AppKit
import ImpKit
import Speech
import SwiftUI

/// Settings every Imp shares: services, talking, animations, permissions and the app itself.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    private var status: SystemStatus { .shared }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(back: router.goHome) {
                HStack(spacing: 7) {
                    Image(systemName: "person.3.fill").font(.system(size: 13)).foregroundStyle(Dungeon.muted)
                    Text("All Imps").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream)
                    InfoTip("Settings every Imp shares. Click an Imp on the stage for its own looks, brain, tools and triggers.")
                }
            } trailing: {
                Text(verbatim: "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
            SegmentedTabs(tabs: GeneralTab.allCases, selection: $router.generalTab, title: \.title, icon: \.icon,
                          badge: { $0 == .permissions && !status.allGranted(Permission.core) })
                .padding(.horizontal, Metrics.pagePadding)
                .frame(maxWidth: Metrics.column)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SettingsPage {
                switch router.generalTab {
                case .services: ServicesPane(model: model)
                case .talking: TalkingPane(model: model)
                case .animations:
                    AnimationsPane(model: model, imp: router.selection)
                case .permissions: PermissionsPage(model: model)
                case .app: AppPane(model: model)
                }
            }
            .id(router.generalTab)
        }
    }
}

/// Every AI service the Imps can use, with its address, key and model.
private struct ServicesPane: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Services", icon: "server.rack",
                 info: "Any OpenAI-compatible API. Imps on a service share its key and model. The star marks the one new Imps use.") {
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Add a service")
            } content: {
                if model.prefs.ai.services.isEmpty {
                    StatusText(text: "None yet.")
                }
                VStack(spacing: 12) {
                    ForEach($model.prefs.ai.services) { $service in
                        ServiceRow(model: model, service: $service) {
                            withAnimation { model.removeService(service.id) }
                        }
                        if service.id != model.prefs.ai.services.last?.id { CardDivider() }
                    }
                }
            }
            Card("Key storage", icon: "lock.fill") {
                Row("Use the Keychain",
                    info: "Off keeps keys in a private file only you can read. On uses the macOS Keychain, which may ask for your password.") {
                    Toggle(String(""), isOn: $model.prefs.keysInKeychain).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) { _ in } }
    }
}

/// How the Imps answer, listen and talk to each other.
private struct TalkingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Answers", icon: "bubble.left.fill") {
                Row("Hide after", info: "Counted from when you're done with an answer. It stays while you hover it or its audio or video plays.") {
                    Picker(String(""), selection: $model.prefs.bubbleAutoHideSeconds) {
                        Text(verbatim: "15 s").tag(15.0)
                        Text(verbatim: "30 s").tag(30.0)
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("Never").tag(0.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                CardDivider()
                Row("Autoplay media", info: "Plays audio and video when an answer asks for it. Otherwise you press play.") {
                    Toggle(String(""), isOn: $model.prefs.autoplaysMedia).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CardDivider()
                Row("Audio look", info: "How audio shows in a bubble. Chats always have players.") {
                    Picker(String(""), selection: $model.prefs.voiceStyle) {
                        Text("Both").tag(VoiceStyle.both)
                        Text("Glow").tag(VoiceStyle.glow)
                        Text("Smoke").tag(VoiceStyle.orb)
                        Text("Players").tag(VoiceStyle.players)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }

            Card("Listening", icon: "mic.fill", info: "Imps hear you with Apple dictation, on your Mac when it can.") {
                Row("Language") {
                    Picker(String(""), selection: $model.prefs.dictationLocale) {
                        Text("Same as my Mac").tag("")
                        Divider()
                        ForEach(Self.locales, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }

            Card("Between Imps", icon: "person.2.fill") {
                Row("Imps talk in",
                    info: "Where a message from one Imp to another goes. Your chat is the one you have with the Imp that receives it.") {
                    Picker(String(""), selection: $model.prefs.impTalk) {
                        ForEach(ImpTalk.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    static let locales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
}

/// The app itself: look, startup, backup and starting over.
private struct AppPane: View {
    @Bindable var model: AppModel
    @State private var loginError: String?
    @State private var confirmingReset = false
    private var status: SystemStatus { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("App", icon: "gearshape.fill") {
                Row("Appearance", info: "Light or dark for bubbles and menus. Auto follows your Mac.") {
                    Picker(String(""), selection: $model.prefs.appearance) {
                        Text("Auto").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                CardDivider()
                Row("Open at login", info: "Imps you let out come back where you left them.") {
                    Toggle(String(""), isOn: Binding(
                        get: { status.launchesAtLogin },
                        set: { on in
                            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                            status.refresh()
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if let loginError { StatusText(verbatim: loginError, symbol: "exclamationmark.triangle.fill", color: .red).help(loginError) }
                CardDivider()
                LanguageRow(model: model)
            }

            Card("Backup", icon: "shippingbox.fill") {
                Row("Export all Imps", info: "Saves every Imp, with its triggers and tools, as one .json file. API keys are never saved.") {
                    Button {
                        ImpExport.save(Set(model.prefs.imps.map(\.id)), model: model, name: String(localized: "All Imps"), fileName: String(localized: "Imps"), shared: true)
                    } label: { Label("Export…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.imp(.secondary, small: true))
                }
                CardDivider()
                Row("Import kit", info: "Adds Imps, triggers or tools from a kit. You choose what to add first.") {
                    Button { HomeWindow.shared.router.kitFlow = KitFlow(imp: nil) } label: { Label("Import…", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.imp(.secondary, small: true))
                }
            }

            Card("Reset", icon: "arrow.counterclockwise") {
                Row("Reset everything", info: "Erases every Imp, service, key, tool, trigger, chat and setting. Imp opens as new.") {
                    Button(role: .destructive) { confirmingReset = true } label: { Label("Reset…", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.imp(.destructive, small: true))
                }
            }
        }
        .confirmationDialog("Erase everything and start over?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Erase and Restart", role: .destructive) { model.resetToFirstLaunch() }
        } message: {
            Text("Every Imp, service, key, tool, trigger, chat and setting is deleted. This can't be undone.")
        }
    }
}

/// The language Imp's text is in: the Mac's, or one just for Imp (the same setting as System
/// Settings › General › Language & Region › Applications). It applies once Imp restarts, so a
/// Restart Now button shows while what's picked isn't what's showing.
private struct LanguageRow: View {
    let model: AppModel
    /// What's picked (nil: the Mac's), read from Imp's own defaults.
    @State private var chosen: String? = LanguageRow.read()
    /// The language this run of Imp shows.
    private static let running = Bundle.main.preferredLocalizations.first ?? "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Row("Language", info: "The language of Imp's menus, settings and bubbles. You can also set it in System Settings › General › Language & Region › Applications. Imps answer in whatever language you write to them.") {
                Picker(String(""), selection: Binding(get: { chosen ?? "" }, set: { pick($0.isEmpty ? nil : $0) })) {
                    Text("Same as my Mac").tag("")
                    Divider()
                    ForEach(AppLanguage.supported, id: \.self) { code in Text(verbatim: AppLanguage.name(code)).tag(code) }
                }
                .labelsHidden().fixedSize()
            }
            if needsRestart {
                HStack(spacing: 8) {
                    StatusText(text: "Imp switches language when it restarts.", symbol: "arrow.clockwise.circle.fill", color: Dungeon.ember)
                    Spacer(minLength: 8)
                    Button { model.relaunch() } label: { Label("Restart Now", systemImage: "arrow.clockwise") }
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
