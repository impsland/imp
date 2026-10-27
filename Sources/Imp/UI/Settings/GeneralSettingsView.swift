import AppKit
import ImpKit
import Speech
import SwiftUI

/// Settings every Imp shares: brain keys, manners, animations, hearing, permissions.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    private var status: SystemStatus { .shared }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(back: router.goHome) {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundStyle(Dungeon.muted)
                    Text("All Imps").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream)
                    InfoTip("Settings every Imp shares. Each Imp's own looks, brain, tools and shortcuts are on its page: click it on the stage.")
                }
            } trailing: {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
            SegmentedTabs(tabs: GeneralTab.allCases, selection: $router.generalTab, title: \.title, icon: \.icon,
                          badge: { $0 == .permissions && !status.allGranted(Permission.allCases) })
                .padding(.horizontal, Metrics.pagePadding)
                .frame(maxWidth: Metrics.column)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SettingsPage {
                switch router.generalTab {
                case .brains: KeysPane(model: model)
                case .manners: MannersPane(model: model)
                case .animations:
                    let imp = router.selection.flatMap(model.profile)
                    AnimationsPane(model: model, hue: imp?.hue ?? 0, favorite: imp.map { $0.isFavorite($0.hue) } ?? false)
                case .hearing: HearingPane(model: model)
                case .permissions: PermissionsPage(model: model)
                }
            }
            .id(router.generalTab)
        }
    }
}

/// Every AI service the Imps can use, with its key.
private struct KeysPane: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Brain services", icon: "key.fill",
                 info: "Any OpenAI-compatible API, with its key and the model its Imps think with: set once here, shared by every Imp on it. The star marks the service new Imps use. On its Brain tab an Imp can pick another service or a model of its own. Keys never leave this Mac except to the service itself.") {
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Add a service")
            } content: {
                if model.prefs.ai.services.isEmpty {
                    StatusText(text: "No services yet.")
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
            Card("Keep keys in the Keychain", icon: "lock.fill",
                 info: "Off (the usual): in a private file on this Mac that only your account can read, so Imp never needs your password. On: in the macOS Keychain, encrypted, but macOS may ask for your password when Imp reads a key (for example after an update). Switching moves the saved keys over.") {
                Toggle("", isOn: $model.prefs.keysInKeychain).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(model.prefs.keysInKeychain ? "Keys are in the Keychain" : "Keep keys in the Keychain")
            } content: {
                EmptyView()
            }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) { _ in } }
    }
}

/// How the Imps behave on your desktop.
private struct MannersPane: View {
    @Bindable var model: AppModel
    @State private var loginError: String?
    private var status: SystemStatus { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Speech bubbles", icon: "bubble.left.fill") {
                Row("Hide after", info: "How long an answer stays up. Never while you hover it.") {
                    Picker("", selection: $model.prefs.bubbleAutoHideSeconds) {
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("Never").tag(0.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                CardDivider()
                Row("Autoplay audio and video", info: "When an Imp's answer asks for it. Otherwise press play.") {
                    Toggle("", isOn: $model.prefs.autoplaysMedia).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CardDivider()
                Row("Bubbles and menus", info: "Light, dark, or like the rest of your Mac.") {
                    Picker("", selection: $model.prefs.appearance) {
                        Text("Auto").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }

            Card("Starting up", icon: "power") {
                Row("Open Imp when I log in", info: "Imps you let out come back right where you left them.") {
                    Toggle("", isOn: Binding(
                        get: { status.launchesAtLogin },
                        set: { on in
                            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                            status.refresh()
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if let loginError { StatusText(text: loginError, symbol: "exclamationmark.triangle.fill", color: .red).help(loginError) }
                CardDivider()
                Row("Quit", info: "Closes Imp and every Imp on your desktop. They come back where they were next time.") {
                    Button(role: .destructive) { NSApp.terminate(nil) } label: { Label("Quit Imp", systemImage: "power") }
                        .buttonStyle(.imp(.destructive, small: true))
                }
            }
        }
    }
}

/// How the Imps hear you.
private struct HearingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Listening", icon: "mic.fill", info: "Imps hear you with Apple dictation, on your Mac when it can.") {
                Row("Language I speak") {
                    Picker("", selection: $model.prefs.dictationLocale) {
                        Text("Same as my Mac").tag("")
                        Divider()
                        ForEach(Self.locales, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }
        }
    }

    static let locales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
}
