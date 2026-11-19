import ImpDesign
import ImpKit
import SwiftUI

/// The Brains section: what each Imp of this iPhone thinks with, which Brain a new Imp starts with, and how long
/// they wait for their Brain. Each Imp has its own service and model, set in its own settings.
struct PhoneBrainsSection: View {
    let pocket: PocketRuntime
    /// Opens an Imp's Brain, to set one up or change it.
    var openBrain: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Card("settings.group.brains", icon: "lightbulb", info: "settings.brains.services.info") {
                if pocket.imps.isEmpty {
                    EmptyState("phone.brains.empty", symbol: "lightbulb")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pocket.imps, id: \.id) { imp in row(imp) }
                    }
                    if let source = pocket.defaultBrainImp {
                        StatusText(verbatim: words("phone.brains.default", source.name), symbol: "plus.circle", color: Tone.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Card("phone.requests.title", icon: "arrow.clockwise", info: "phone.requests.info") {
                limitRow("phone.requests.timeout.title", icon: "hourglass", info: "phone.requests.timeout.info",
                         value: limit(\.timeoutSeconds), range: RequestLimits.timeoutControlRange, step: RequestLimits.timeoutStep) { "\(Int($0)) s" }
                limitRow("phone.requests.retries.title", icon: "arrow.triangle.2.circlepath", info: "phone.requests.retries.info",
                         value: limit(\.retries, as: Double.self),
                         range: Double(RequestLimits.retriesRange.lowerBound)...Double(RequestLimits.retriesRange.upperBound), step: 1) { "\(Int($0))" }
                limitRow("phone.requests.delay.title", icon: "pause.circle", info: "phone.requests.delay.info",
                         value: limit(\.retryDelaySeconds), range: RequestLimits.delayRange, step: RequestLimits.delayStep) { "\($0.formatted()) s" }
                limitRow("phone.requests.backoff.title", icon: "chart.line.uptrend.xyaxis", info: "phone.requests.backoff.info",
                         value: limit(\.backoff), range: RequestLimits.backoffRange, step: RequestLimits.backoffStep) { "× \($0.formatted())" }
            }
        }
    }

    /// One Imp: its colour, its name and what it thinks with, or Set up when it sleeps.
    private func row(_ imp: PocketImp) -> some View {
        let ready = pocket.hasBrain(imp.id)
        return Button { openBrain(imp.id) } label: {
            HStack(spacing: Spacing.cozy) {
                Circle().fill(Color.imp(imp.hue)).frame(width: Spacing.medium, height: Spacing.medium).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: imp.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                    Text(verbatim: ready ? [imp.brain.label ?? "", imp.brain.model].filter { !$0.isEmpty }.joined(separator: " · ")
                                         : String(localized: "imp_settings.value.asleep"))
                        .font(Typeface.caption).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Spacing.small)
                if ready {
                    Image(systemName: "chevron.right").font(.icon(.small, weight: .semibold)).foregroundStyle(Tone.faint)
                        .accessibilityHidden(true)
                } else {
                    FitLabel("phone.brains.set_up", systemImage: ImpSetting.brain.symbol)
                        .impPill(.secondary, small: true)
                }
            }
            .frame(minHeight: Sizing.hit)
            .padding(.vertical, Spacing.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(ready ? "phone.brain.change" : "phone.brains.set_up"))
    }

    private func limitRow(_ title: LocalizedStringKey, icon: String, info: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                          text: @escaping (Double) -> String) -> some View {
        Row(title, icon: icon, info: info) {
            ImpStepper(value: value, in: range, step: step) { Text(verbatim: text(value.wrappedValue)) }
                .accessibilityLabel(title)
        }
    }

    /// One of the limits as a number to step. Changes count from the next request.
    private func limit(_ path: WritableKeyPath<RequestLimits, Double>) -> Binding<Double> {
        Binding(get: { pocket.limits[keyPath: path] },
                set: { var l = pocket.limits; l[keyPath: path] = $0; pocket.setLimits(l) })
    }

    private func limit(_ path: WritableKeyPath<RequestLimits, Int>, as: Double.Type) -> Binding<Double> {
        Binding(get: { Double(pocket.limits[keyPath: path]) },
                set: { var l = pocket.limits; l[keyPath: path] = Int($0); pocket.setLimits(l) })
    }
}
