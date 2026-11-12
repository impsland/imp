import ImpDesign
import ImpKit
import Speech
import SwiftUI

/// How the Imps listen, talk to each other and cope with long chats.
struct TalkingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("settings.talking.listening.title", icon: "mic.fill", info: "settings.talking.listening.info") {
                Row("settings.talking.language.title", icon: "character.bubble.fill") {
                    ImpPicker("settings.talking.language.title", selection: $model.prefs.dictationLocale, options: [""] + Self.locales) { id in
                        id.isEmpty ? String(localized: "Same as my Mac") : (Locale.current.localizedString(forIdentifier: id) ?? id)
                    }
                }
                .settingAnchor(.talkingListeningLanguage)
            }

            Card("settings.talking.between.title", icon: "person.2.fill", info: "settings.talking.between.info") {
                Row("settings.talking.talk_in.title", icon: "arrow.left.arrow.right") {
                    ImpPicker("settings.talking.talk_in.title", selection: $model.prefs.impTalk, options: Array(ImpTalk.allCases)) { $0.title }
                }
                .settingAnchor(.talkingTalkIn)
                Row("settings.talking.threads.title", icon: "text.bubble", info: "settings.talking.threads.info") {
                    ImpPicker("settings.talking.threads.title", selection: $model.prefs.talkThreading, options: TalkThreading.allCases) { $0.title }
                }
                .settingAnchor(.talkingThreads)
                if model.prefs.talkThreading == .recent || model.prefs.talkThreading == .decides {
                    Row("settings.talking.window.title", icon: "clock", info: "settings.talking.window.info") {
                        ImpStepper(value: $model.prefs.talkWindowMinutes, in: 1...TalkThreading.maxWindowMinutes, step: 15) {
                            Text("\(model.prefs.talkWindowMinutes) min")
                        }
                    }
                    .settingAnchor(.talkingWindow)
                }
            }

            Card("settings.talking.long.title", icon: "text.alignleft", info: "settings.talking.long.info") {
                Row("settings.talking.suggest.title", icon: "lightbulb.fill") {
                    ImpPicker("settings.talking.suggest.title", selection: $model.prefs.contextNoticeTokens,
                              options: ImpPreferences.contextNoticeChoices) {
                        $0 >= 1_000_000 ? String(localized: "\($0 / 1_000_000)M") : String(localized: "\($0 / 1000)k")
                    }
                }
                .settingAnchor(.talkingSuggest)
            }
        }
    }

    static let locales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
}
