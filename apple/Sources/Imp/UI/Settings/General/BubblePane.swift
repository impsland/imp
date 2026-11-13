import ImpDesign
import ImpKit
import SwiftUI

/// How the bubble that carries an Imp's answers behaves.
struct BubblePane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("settings.bubble.look.title", icon: "paintbrush.fill") {
                Row("settings.bubble.background.title", icon: "circle.lefthalf.filled", info: "settings.bubble.background.info") {
                    ImpSegmented("settings.bubble.background.title", selection: $model.prefs.bubbleAppearance.style,
                                 options: BubbleAppearance.Style.allCases, title: { style in
                        switch style {
                        case .solid: String(localized: "settings.bubble.background.solid")
                        case .translucent: String(localized: "settings.bubble.background.translucent")
                        }
                    }, symbol: { style in
                        switch style {
                        case .solid: "circle.fill"
                        case .translucent: "circle.dotted"
                        }
                    })
                }
                .settingAnchor(.bubbleBackground)
                if model.prefs.bubbleAppearance.style == .translucent {
                    Row("settings.bubble.amount.title", icon: "slider.horizontal.3", info: "settings.bubble.amount.info") {
                        RowSlider(value: $model.prefs.bubbleAppearance.opacity,
                                  range: BubbleAppearance.minimumOpacity...1, step: 0.05,
                                  label: "settings.bubble.amount.title",
                                  shown: model.prefs.bubbleAppearance.opacity.formatted(.percent.precision(.fractionLength(0))),
                                  resets: BubbleAppearance.defaultOpacity)
                    }
                    .settingAnchor(.bubbleAmount)
                }
                BubblePreview(appearance: model.prefs.bubbleAppearance)
            }
            Card("settings.bubble.showing.title", icon: "text.bubble.fill", info: "settings.bubble.showing.info") {
                Row("settings.bubble.hide.title", icon: "timer", info: "settings.bubble.hide.info") {
                    ImpSegmented("settings.bubble.hide.title", selection: $model.prefs.bubbleAutoHideSeconds,
                                 options: [15.0, 30.0, 60.0, 300.0, 0.0], title: { seconds in
                        switch seconds {
                        case 15: "15 s"
                        case 30: "30 s"
                        case 60: String(localized: "1 min")
                        case 300: String(localized: "5 min")
                        default: String(localized: "Never")
                        }
                    }, symbol: { seconds in
                        switch seconds {
                        case 15: "hare.fill"
                        case 30: "timer"
                        case 60: "clock.fill"
                        case 300: "tortoise.fill"
                        default: "infinity"
                        }
                    })
                }
                .settingAnchor(.bubbleHideAfter)
                Row("settings.bubble.lines.title", icon: "text.alignleft", info: "settings.bubble.lines.info") {
                    ImpStepper(value: $model.prefs.inputMaxLines, in: BubbleSizing.inputLines) {
                        Text("\(model.prefs.inputMaxLines)")
                    }
                }
                .settingAnchor(.bubbleLines)
                Row("settings.bubble.size.title", icon: "arrow.up.left.and.arrow.down.right", info: "settings.bubble.size.info") {
                    HStack(spacing: Spacing.small) {
                        if let size = model.prefs.chatBubbleSize {
                            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").foregroundStyle(Tone.muted)
                        } else {
                            Text("Default").foregroundStyle(Tone.muted)
                        }
                        Button { model.prefs.chatBubbleSize = nil } label: { FitLabel("Reset size", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(.imp(.secondary, small: true))
                            .disabled(model.prefs.chatBubbleSize == nil)
                    }
                }
                .settingAnchor(.bubbleSize)
            }
            Card("settings.bubble.media.title", icon: "play.rectangle.fill", info: "settings.bubble.media.info") {
                Row("settings.bubble.autoplay.title", icon: "play.circle.fill", info: "settings.bubble.autoplay.info") {
                    Toggle(String(""), isOn: $model.prefs.autoplaysMedia).labelsHidden().toggleStyle(.impSwitchBare)
                }
                .settingAnchor(.bubbleAutoplay)
                Row("settings.bubble.audio.title", icon: "waveform", info: "settings.bubble.audio.info") {
                    ImpSegmented("settings.bubble.audio.title", selection: $model.prefs.voiceStyle,
                                 options: [VoiceStyle.both, .glow, .orb, .players], title: { style in
                        switch style {
                        case .both: String(localized: "Both")
                        case .glow: String(localized: "Glow")
                        case .orb: String(localized: "Smoke")
                        case .players: String(localized: "Players")
                        }
                    }, symbol: { style in
                        switch style {
                        case .both: "square.stack.fill"
                        case .glow: "sun.max.fill"
                        case .orb: "smoke.fill"
                        case .players: "play.rectangle.fill"
                        }
                    })
                }
                .settingAnchor(.bubbleAudio)
            }
        }
    }
}
