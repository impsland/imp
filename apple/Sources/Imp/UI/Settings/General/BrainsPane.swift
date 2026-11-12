import ImpDesign
import ImpKit
import SwiftUI

/// Every AI service the Imps can use, with its address, key and model.
struct BrainsPane: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Card("settings.group.brains", icon: SettingsGroup.brains.symbol, info: "settings.brains.services.info") {
                    Button { adding = true } label: { FitLabel("brains.add", systemImage: "plus") }
                        .buttonStyle(.imp(.secondary, small: true))
                } content: {
                    if model.prefs.ai.services.isEmpty {
                        StatusText(text: "brains.empty")
                    }
                }
                .settingAnchor(.brainsServices)
                ForEach($model.prefs.ai.services) { $service in
                    ServiceRow(model: model, service: $service) {
                        withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.removeService(service.id) }
                    }
                }
            }
            Card("settings.brains.keys.title", icon: "key.fill", info: "settings.brains.keys.info") {
                Row("settings.brains.keychain.title", icon: "lock.fill", info: "settings.brains.keychain.info") {
                    Toggle(String(""), isOn: $model.prefs.keysInKeychain).labelsHidden().toggleStyle(.impSwitchBare)
                }
                .settingAnchor(.brainsKeychain)
            }
            Card("settings.brains.requests.title", icon: "arrow.clockwise", info: "settings.brains.requests.info") {
                Row("settings.brains.wait.title", icon: "hourglass") {
                    ImpStepper(value: $model.prefs.requests.timeoutSeconds, in: RequestLimits.timeoutControlRange, step: RequestLimits.timeoutStep) {
                        Text("\(Int(model.prefs.requests.timeoutSeconds)) s")
                    }
                }
                .settingAnchor(.brainsWait)
                Row("settings.brains.retries.title", icon: "arrow.counterclockwise", info: "settings.brains.retries.info") {
                    ImpStepper(value: $model.prefs.requests.retries, in: RequestLimits.retriesRange) {
                        Text("\(model.prefs.requests.retries)")
                    }
                }
                .settingAnchor(.brainsRetries)
                Row("settings.brains.first_wait.title", icon: "clock", info: "settings.brains.first_wait.info") {
                    ImpStepper(value: $model.prefs.requests.retryDelaySeconds, in: RequestLimits.delayRange, step: RequestLimits.delayStep) {
                        Text("\(model.prefs.requests.retryDelaySeconds.formatted()) s")
                    }
                }
                .settingAnchor(.brainsFirstWait)
                Row("settings.brains.longer.title", icon: "chart.line.uptrend.xyaxis", info: "settings.brains.longer.info") {
                    ImpStepper(value: $model.prefs.requests.backoff, in: RequestLimits.backoffRange, step: RequestLimits.backoffStep) {
                        Text("× \(model.prefs.requests.backoff.formatted())")
                    }
                }
                .settingAnchor(.brainsLonger)
            }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) { _ in } }
    }
}
