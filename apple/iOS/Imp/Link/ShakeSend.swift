import ImpDesign
import ImpKit
import SwiftUI

/// Where a shaken Imp went, shown for a few seconds with a way to take it back.
struct ShakeReceipt: Equatable {
    enum State { case sending, arrived }
    /// How long "Undo" stays.
    static let undoSeconds = 6.0

    var imp: UUID
    var impName: String
    var device: UUID
    var deviceName: String
    var state: State
}

/// A shake that needs the person to pick: the Imp that would go and the devices it could go to.
struct ShakeAsk: Identifiable {
    var id = UUID()
    var imp: UUID
    var impName: String
    var choices: [LinkDevice]
    var why: ShakeTransfer.Why

    var title: String {
        choices.count == 1 ? String(localized: "Send \(impName) to \(choices[0].name)?") : String(localized: "Where should \(impName) go?")
    }

    var message: String {
        switch why {
        case .severalNearby: String(localized: "More than one of your devices is nearby.")
        case .friend: String(localized: "\(choices.first?.name ?? "This device") isn't marked as yours, so whoever uses it will see \(impName).")
        case .farAway: String(localized: "Nothing has been seen nearby lately, so \(choices.count == 1 ? "this device" : "these devices") may be far away.")
        }
    }
}

/// "Pip is on Studio Mac" with Undo, or "Sending Pip to Studio Mac" while it flies.
struct ShakeReceiptBar: View {
    let hub: LinkHub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let receipt = hub.shakeReceipt {
                HStack(spacing: Spacing.cozy) {
                    switch receipt.state {
                    case .sending:
                        ProgressView().controlSize(.small).tint(Tone.accentBright)
                        Text("Sending \(receipt.impName) to \(receipt.deviceName)")
                    case .arrived:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.accentBright)
                        Text("\(receipt.impName) is on \(receipt.deviceName)")
                        Button("Undo") { hub.undoShake() }
                            .buttonStyle(.secondary)
                            .accessibilityHint("Brings \(receipt.impName) back")
                    }
                }
                .font(Typeface.label)
                .foregroundStyle(Tone.text)
                .padding(.leading, Spacing.large).padding(.trailing, receipt.state == .arrived ? Spacing.small : Spacing.large).padding(.vertical, Spacing.small)
                .background(Tone.raised, in: Capsule())
                .impControls(tint: Tone.accent)
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .impAnimation(ImpDesign.Motion.spring, value: hub.shakeReceipt)
    }
}

/// The shake settings, in the Devices sheet.
struct ShakeSettingsCard: View {
    @AppStorage(ShakeSettings.enabledKey) private var enabled = true
    @AppStorage(ShakeSettings.sensitivityKey) private var sensitivity = ShakeSettings.Sensitivity.normal.rawValue
    @AppStorage(ShakeSettings.directionKey) private var direction = ShakeSettings.Direction.either.rawValue
    @AppStorage(ShakeSettings.friendsKey) private var asksForFriends = true

    var body: some View {
        Card("phone.shake.title", icon: "iphone.gen3.radiowaves.left.and.right", info: "phone.shake.info",
             accessory: {
                 Toggle("phone.shake.title", isOn: $enabled).toggleStyle(.impSwitchBare)
             }) {
            if enabled {
                Row("phone.shake.hard.title", icon: "gauge.with.dots.needle.50percent") {
                    ImpSegmented("phone.shake.hard.title", selection: $sensitivity,
                                 options: [ShakeSettings.Sensitivity.gentle.rawValue, ShakeSettings.Sensitivity.normal.rawValue, ShakeSettings.Sensitivity.firm.rawValue],
                                 title: {
                        switch $0 {
                        case ShakeSettings.Sensitivity.gentle.rawValue: String(localized: "phone.shake.gentle")
                        case ShakeSettings.Sensitivity.firm.rawValue: String(localized: "phone.shake.firm")
                        default: String(localized: "phone.shake.normal")
                        }
                    }, symbol: {
                        switch $0 {
                        case ShakeSettings.Sensitivity.gentle.rawValue: "wind"
                        case ShakeSettings.Sensitivity.firm.rawValue: "bolt.fill"
                        default: "iphone.gen3.radiowaves.left.and.right"
                        }
                    })
                }
                Row("phone.shake.which.title", icon: "arrow.left.arrow.right") {
                    ImpSegmented("phone.shake.which.title", selection: $direction,
                                 options: [ShakeSettings.Direction.either.rawValue, ShakeSettings.Direction.leftRight.rawValue],
                                 title: { $0 == ShakeSettings.Direction.leftRight.rawValue ? String(localized: "phone.shake.dir.sides") : String(localized: "phone.shake.dir.any") },
                                 symbol: { $0 == ShakeSettings.Direction.leftRight.rawValue ? "arrow.left.arrow.right" : "arrow.up.and.down.and.arrow.left.and.right" })
                }
                Row("phone.shake.friends.title", icon: "person.2.fill") {
                    Toggle("phone.shake.friends.title", isOn: $asksForFriends).toggleStyle(.impSwitchBare)
                }
            }
        }
        .impControls(tint: Tone.accent)
        .accessibilityElement(children: .contain)
    }
}
