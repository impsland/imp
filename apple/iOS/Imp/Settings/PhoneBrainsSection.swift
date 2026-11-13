import ImpDesign
import ImpKit
import SwiftUI

/// The Brains section: which Imps of this iPhone can think, and how long they wait for their Brain.
/// Each Imp has its own service and model, set in its own settings.
struct PhoneBrainsSection: View {
    let pocket: PocketRuntime

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Card("settings.group.brains", icon: "lightbulb", info: "settings.brains.services.info") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pocket.imps, id: \.id) { imp in
                        let ready = pocket.hasBrain(imp.id)
                        HStack(spacing: Spacing.cozy) {
                            Circle().fill(Color.imp(imp.look.hue)).frame(width: Spacing.small, height: Spacing.small).accessibilityHidden(true)
                            Text(verbatim: imp.look.name).font(Typeface.body).foregroundStyle(Tone.text)
                            Spacer(minLength: Spacing.small)
                            StatusText(text: ready ? "settings.map.state_ready" : "settings.map.state_needs_setup",
                                       symbol: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                       color: ready ? Tone.good : Tone.warnText)
                        }
                        .frame(minHeight: Sizing.hit)
                        .accessibilityElement(children: .combine)
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
