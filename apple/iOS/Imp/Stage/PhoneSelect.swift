import ImpDesign
import ImpKit
import SwiftUI

/// Several Imps picked at once on the phone (the Mac's `ImpPicks`, by touch): Select in an Imp's menu starts it,
/// a tap on an Imp then picks it or lets it go, and a bar at the bottom acts on all of them.

/// Tells the app that Imps are being picked: the room's top bar gives its place to the picking bar.
struct PhonePicking: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The mark on an Imp while picking: a tick in its own colour when picked, a quiet dot when it can be.
struct PickBadge: View {
    let hue: Double
    let picked: Bool

    var body: some View {
        ZStack {
            Circle().fill(picked ? AnyShapeStyle(TintFill(Color.imp(hue))) : AnyShapeStyle(Tone.scrim))
            if picked {
                Image(systemName: "checkmark")
                    .font(.icon(.medium, weight: .bold))
                    .foregroundStyle(OnTint(Color.imp(hue)))
            }
        }
        .frame(width: Sizing.glyph, height: Sizing.glyph)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Cancel, how many are picked, and Select All.
struct PickTopBar: View {
    let count: Int
    let everyone: Bool
    var cancel: () -> Void
    var selectAll: () -> Void

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Button(action: cancel) { Text("common.cancel") }
                .buttonStyle(ImpButtonStyle(kind: .quiet, small: true))
                .accessibilityIdentifier("pick.cancel")
            Text(words("phone.select.title", count))
                .font(Typeface.body.weight(.semibold))
                .foregroundStyle(Tone.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pick.title")
                .accessibilityAddTraits(.isHeader)
            Button(action: selectAll) { Text("phone.select.all") }
                .buttonStyle(ImpButtonStyle(kind: .quiet, small: true))
                .disabled(everyone)
                .accessibilityIdentifier("pick.all")
        }
        .padding(.horizontal, Spacing.page)
        .frame(minHeight: Sizing.hit)
    }
}

/// What the picked Imps can be sent to do. A kind that none of them can do is not offered.
struct PickBottomBar: View {
    let canSendHome: Bool
    let canSayGoodbye: Bool
    var hide: () -> Void
    var sendHome: () -> Void
    var sayGoodbye: () -> Void

    var body: some View {
        HStack(spacing: Spacing.small) {
            action("menu.imp.hide", symbol: "eye.slash", id: "pick.hide", run: hide)
            if canSendHome { action("menu.imp.send_home", symbol: "house.fill", id: "pick.home", run: sendHome) }
            if canSayGoodbye { action("menu.imp.goodbye", symbol: "hand.wave.fill", id: "pick.goodbye", danger: true, run: sayGoodbye) }
        }
        .padding(Spacing.small)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .padding(.horizontal, Spacing.page)
        .padding(.bottom, Spacing.small)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, id: String, danger: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: Spacing.hairline) {
                Image(systemName: symbol).font(.icon(.big, weight: .medium))
                Text(title).font(Typeface.small).lineLimit(1)
            }
            .foregroundStyle(danger ? Tone.danger : Tone.text)
            .frame(maxWidth: .infinity, minHeight: Sizing.control + Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
