import AppKit
import ImpDesign
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
                .padding(.horizontal, Spacing.page)
                .frame(maxWidth: Metrics.column)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SettingsPage {
                switch router.generalTab {
                case .services: ServicesPane(model: model)
                case .talking: TalksPane(model: model)
                case .animations:
                    AnimationsPane(model: model, imp: router.selection)
                case .permissions: PermissionsPage(model: model)
                case .devices: DevicesPane(model: model)
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
        VStack(alignment: .leading, spacing: Spacing.medium) {
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
                    Toggle(String(""), isOn: $model.prefs.keysInKeychain).labelsHidden().toggleStyle(.impSwitchBare)
                }
            }
            Card("Requests", icon: "arrow.clockwise", info: "How long an Imp waits for a model, and what it does when the network drops for a moment.") {
                Row("Wait up to", info: "A request that hasn't finished after this long ends with a message instead of waiting on.") {
                    ImpStepper(value: $model.prefs.requests.timeoutSeconds, in: RequestLimits.timeoutControlRange, step: RequestLimits.timeoutStep) {
                        Text("\(Int(model.prefs.requests.timeoutSeconds)) s")
                    }
                }
                CardDivider()
                Row("Retries", info: "How many times a request is tried again after the network drops or the service is busy. Wrong keys and bad requests are never retried.") {
                    ImpStepper(value: $model.prefs.requests.retries, in: RequestLimits.retriesRange) {
                        Text("\(model.prefs.requests.retries)")
                    }
                }
                CardDivider()
                Row("First wait", info: "The pause before the first retry.") {
                    ImpStepper(value: $model.prefs.requests.retryDelaySeconds, in: RequestLimits.delayRange, step: RequestLimits.delayStep) {
                        Text("\(model.prefs.requests.retryDelaySeconds.formatted()) s")
                    }
                }
                CardDivider()
                Row("Longer each time", info: "Each pause is this many times longer than the one before.") {
                    ImpStepper(value: $model.prefs.requests.backoff, in: RequestLimits.backoffRange, step: RequestLimits.backoffStep) {
                        Text("× \(model.prefs.requests.backoff.formatted())")
                    }
                }
            }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) { _ in } }
    }
}

/// How the Imps answer, listen and talk to each other.
private struct TalksPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("Answers", icon: "bubble.left.fill") {
                Row("Hide after", info: "Counted from when you're done with an answer. It stays while you hover it or its audio or video plays.") {
                    ImpSegmented("Hide after", selection: $model.prefs.bubbleAutoHideSeconds,
                                 options: [15.0, 30.0, 60.0, 300.0, 0.0]) { seconds in
                        switch seconds {
                        case 15: "15 s"
                        case 30: "30 s"
                        case 60: String(localized: "1 min")
                        case 300: String(localized: "5 min")
                        default: String(localized: "Never")
                        }
                    }
                }
                CardDivider()
                Row("Text box lines", info: "How many lines the text box grows to as you type before it scrolls.") {
                    ImpStepper(value: $model.prefs.inputMaxLines, in: BubbleSizing.inputLines) {
                        Text("\(model.prefs.inputMaxLines)")
                    }
                }
                CardDivider()
                Row("Chat size", info: "Drag an edge or corner of the chat bubble to resize it. The size is kept for next time.") {
                    HStack(spacing: 8) {
                        if let size = model.prefs.chatBubbleSize {
                            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").foregroundStyle(.secondary)
                        } else {
                            Text("Default").foregroundStyle(.secondary)
                        }
                        Button("Reset size") { model.prefs.chatBubbleSize = nil }
                            .buttonStyle(.imp(.secondary, small: true))
                            .disabled(model.prefs.chatBubbleSize == nil)
                    }
                }
                CardDivider()
                Row("Autoplay media", info: "Plays audio and video when an answer asks for it. Otherwise you press play.") {
                    Toggle(String(""), isOn: $model.prefs.autoplaysMedia).labelsHidden().toggleStyle(.impSwitchBare)
                }
                CardDivider()
                Row("Audio look", info: "How audio shows in a bubble. Chats always have players.") {
                    ImpSegmented("Audio look", selection: $model.prefs.voiceStyle,
                                 options: [VoiceStyle.both, .glow, .orb, .players]) { style in
                        switch style {
                        case .both: String(localized: "Both")
                        case .glow: String(localized: "Glow")
                        case .orb: String(localized: "Smoke")
                        case .players: String(localized: "Players")
                        }
                    }
                }
            }

            Card("Listening", icon: "mic.fill", info: "Imps hear you with Apple dictation, on your Mac when it can.") {
                Row("Language") {
                    ImpPicker("Language", selection: $model.prefs.dictationLocale, options: [""] + Self.locales, maxWidth: 260) { id in
                        id.isEmpty ? String(localized: "Same as my Mac") : (Locale.current.localizedString(forIdentifier: id) ?? id)
                    }
                }
            }

            Card("Between Imps", icon: "person.2.fill") {
                Row("Imps talk in",
                    info: "Where a message from one Imp to another goes. Your chat is the one you have with the Imp that receives it.") {
                    ImpPicker("Imps talk in", selection: $model.prefs.impTalk, options: Array(ImpTalk.allCases)) { $0.title }
                }
                CardDivider()
                Row("Conversations",
                    info: "Whether a message to an Imp goes on in your latest conversation with it or starts a new one. “The Imp decides” lets the sender choose, and falls back to the time below when it doesn't. Only for chats of their own.") {
                    ImpPicker("Conversations", selection: $model.prefs.talkThreading, options: TalkThreading.allCases) { $0.title }
                }
                if model.prefs.talkThreading == .recent || model.prefs.talkThreading == .decides {
                    CardDivider()
                    Row("Same conversation for", info: "A message sent within this time of the last one between two Imps continues their conversation. Later ones start a new one.") {
                        ImpStepper(value: $model.prefs.talkWindowMinutes, in: 1...TalkThreading.maxWindowMinutes, step: 15) {
                            Text("\(model.prefs.talkWindowMinutes) min")
                        }
                    }
                }
            }

            Card("Long chats", icon: "text.alignleft",
                 info: "A chat that grows this long gets one gentle suggestion to recap it or start a new chat. Nothing is cut or blocked. The size is an estimate of what an Imp sends with each message, about four characters per token.") {
                Row("Suggest at") {
                    ImpPicker("Suggest at", selection: $model.prefs.contextNoticeTokens,
                              options: ImpPreferences.contextNoticeChoices) {
                        $0 >= 1_000_000 ? String(localized: "\($0 / 1_000_000)M") : String(localized: "\($0 / 1000)k")
                    }
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
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("App", icon: "gearshape.fill") {
                Row("Appearance", info: "Light or dark for bubbles and menus. Auto follows your Mac.") {
                    ImpSegmented("Appearance", selection: $model.prefs.appearance,
                                 options: [Appearance.system, .light, .dark]) { appearance in
                        switch appearance {
                        case .system: String(localized: "Auto")
                        case .light: String(localized: "Light")
                        case .dark: String(localized: "Dark")
                        }
                    }
                }
                CardDivider()
                Row("Open at login", info: "Imps you let out come back where you left them.") {
                    Toggle(String(""), isOn: Binding(
                        get: { status.launchesAtLogin },
                        set: { on in
                            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                            status.refresh()
                        })).labelsHidden().toggleStyle(.impSwitchBare)
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
                ImpPicker("Language", selection: Binding(get: { chosen ?? "" }, set: { pick($0.isEmpty ? nil : $0) }),
                          options: [""] + AppLanguage.supported) { code in
                    code.isEmpty ? String(localized: "Same as my Mac") : AppLanguage.name(code)
                }
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
