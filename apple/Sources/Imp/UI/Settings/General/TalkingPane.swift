import ImpDesign
import ImpKit
import Speech
import SwiftUI

/// How the Imps listen and talk to each other.
struct TalkingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("settings.talking.listening.title", icon: "mic.fill", info: "settings.talking.listening.info") {
                Row("settings.talking.language.title", icon: "character.bubble.fill", info: "settings.talking.language.info") {
                    ImpPicker("settings.talking.language.title", selection: $model.prefs.dictationLocale,
                              options: ["", ListeningLanguages.automatic] + Self.locales) { id in
                        switch id {
                        case "": String(localized: "Same as my Mac")
                        case ListeningLanguages.automatic: String(localized: "settings.talking.language.auto")
                        default: Self.name(id)
                        }
                    }
                }
                .settingAnchor(.talkingListeningLanguage)
                if model.prefs.dictationLocale == ListeningLanguages.automatic {
                    Row("settings.talking.languages.title", icon: "globe", info: "settings.talking.languages.info") {
                        languages
                    }
                    .settingAnchor(.talkingListeningLanguages)
                }
            }

            Card("settings.talking.between.title", icon: "person.2.fill", info: "settings.talking.between.info") {
                Row("settings.talking.talk_in.title", icon: "arrow.left.arrow.right", info: "settings.talking.talk_in.info") {
                    ImpSegmented("settings.talking.talk_in.title", selection: $model.prefs.impTalk, options: Array(ImpTalk.allCases),
                                 title: { $0.title }, symbol: { $0.symbol })
                }
                .settingAnchor(.talkingTalkIn)
                Row("settings.talking.threads.title", icon: "text.bubble", info: "settings.talking.threads.info") {
                    ImpSegmented("settings.talking.threads.title", selection: $model.prefs.talkThreading, options: TalkThreading.allCases,
                                 title: { $0.title }, symbol: { $0.symbol })
                }
                .settingAnchor(.talkingThreads)
                Row("settings.talking.waiting.title", icon: "hourglass", info: "settings.talking.waiting.info") {
                    ImpSegmented("settings.talking.waiting.title", selection: $model.prefs.talkWaiting, options: TalkWaiting.allCases,
                                 title: { $0.title }, symbol: { $0.symbol })
                }
                .settingAnchor(.talkingWaiting)
                if model.prefs.talkThreading == .recent || model.prefs.talkThreading == .decides {
                    Row("settings.talking.window.title", icon: "clock", info: "settings.talking.window.info") {
                        ImpStepper(value: $model.prefs.talkWindowMinutes, in: 1...TalkThreading.maxWindowMinutes, step: 15) {
                            Text("\(model.prefs.talkWindowMinutes) min")
                        }
                    }
                    .settingAnchor(.talkingWindow)
                }
            }
        }
    }

    /// The languages Automatic listens for: the person's picks (up to three), or the Mac's own.
    private var languages: some View {
        let picked = model.prefs.dictationLanguages
        let title = picked.isEmpty ? String(localized: "settings.talking.languages.device")
            : picked.map(Self.name).formatted(.list(type: .and, width: .narrow))
        return CompactMenu(verbatim: title, symbol: "globe") {
            Button { model.prefs.dictationLanguages = [] } label: {
                if picked.isEmpty { Label("settings.talking.languages.device", systemImage: "checkmark") } else { Text("settings.talking.languages.device") }
            }
            Section("settings.talking.languages.pick") {
                ForEach(Self.locales, id: \.self) { id in
                    let on = picked.contains(id)
                    Button {
                        model.prefs.dictationLanguages = on ? picked.filter { $0 != id } : picked + [id]
                    } label: {
                        if on { Label(Self.name(id), systemImage: "checkmark") } else { Text(verbatim: Self.name(id)) }
                    }
                    .disabled(!on && picked.count >= ListeningLanguages.maxLanguages)
                }
            }
        }
    }

    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    static let locales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
}

extension ImpTalk {
    var symbol: String {
        switch self {
        case .own: "bubble.left.and.bubble.right"
        case .shared: "bubble.left"
        case .decides: "sparkles"
        }
    }
}

extension TalkWaiting {
    var symbol: String {
        switch self {
        case .wait: "hourglass"
        case .dontWait: "paperplane"
        case .decides: "sparkles"
        }
    }
}

extension TalkThreading {
    var symbol: String {
        switch self {
        case .decides: "sparkles"
        case .recent: "clock.arrow.circlepath"
        case .always: "arrow.turn.down.right"
        case .never: "plus.bubble"
        }
    }
}
