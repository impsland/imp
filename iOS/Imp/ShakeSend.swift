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
                HStack(spacing: 10) {
                    switch receipt.state {
                    case .sending:
                        ProgressView().controlSize(.small).tint(Dungeon.flame)
                        Text("Sending \(receipt.impName) to \(receipt.deviceName)")
                    case .arrived:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Dungeon.flame)
                        Text("\(receipt.impName) is on \(receipt.deviceName)")
                        Button("Undo") { hub.undoShake() }
                            .buttonStyle(.secondary)
                            .accessibilityHint("Brings \(receipt.impName) back")
                    }
                }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.cream)
                .padding(.leading, 16).padding(.trailing, receipt.state == .arrived ? 8 : 16).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                .impControls(tint: Dungeon.ember)
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: hub.shakeReceipt)
    }
}

/// The shake settings, in the Devices sheet.
struct ShakeSettingsCard: View {
    @AppStorage(ShakeSettings.enabledKey) private var enabled = true
    @AppStorage(ShakeSettings.sensitivityKey) private var sensitivity = ShakeSettings.Sensitivity.normal.rawValue
    @AppStorage(ShakeSettings.directionKey) private var direction = ShakeSettings.Direction.either.rawValue
    @AppStorage(ShakeSettings.friendsKey) private var asksForFriends = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                Text("Shake to send").font(Typeface.label).foregroundStyle(Dungeon.cream)
            }
            .toggleStyle(.impSwitch)
            Text("Shake your iPhone next to a linked device and the Imp you moved last goes to it. You see where it went and can undo it.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            if enabled {
                Text("How hard").font(Typeface.caption).foregroundStyle(Dungeon.muted)
                ImpSegmented("How hard", selection: $sensitivity,
                             options: [ShakeSettings.Sensitivity.gentle.rawValue, ShakeSettings.Sensitivity.normal.rawValue, ShakeSettings.Sensitivity.firm.rawValue]) {
                    switch $0 {
                    case ShakeSettings.Sensitivity.gentle.rawValue: String(localized: "Gentle")
                    case ShakeSettings.Sensitivity.firm.rawValue: String(localized: "Firm")
                    default: String(localized: "Normal")
                    }
                }
                Text("Which device").font(Typeface.caption).foregroundStyle(Dungeon.muted)
                ImpSegmented("Which device", selection: $direction,
                             options: [ShakeSettings.Direction.either.rawValue, ShakeSettings.Direction.leftRight.rawValue]) {
                    $0 == ShakeSettings.Direction.leftRight.rawValue ? String(localized: "Left or right") : String(localized: "Any way")
                }
                Text(direction == ShakeSettings.Direction.leftRight.rawValue
                     ? "With two devices nearby, shake to the right for the first by name and to the left for the second. Otherwise Imp asks."
                     : "The direction doesn't matter. If more than one device is nearby, Imp asks which.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
                Toggle(isOn: $asksForFriends) {
                    Text("Ask before sending to a friend").font(Typeface.label).foregroundStyle(Dungeon.cream)
                }
                .toggleStyle(.impSwitch)
                Text("A linked device you haven't marked as Mine belongs to someone else.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            }
        }
        .padding(14)
        .impCard()
        .impControls(tint: Dungeon.ember)
        .accessibilityElement(children: .contain)
    }
}
