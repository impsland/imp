import ImpDesign
import ImpKit
import SwiftUI

/// Settings every Imp shares: the bar, the rail of sections and the page of the chosen one. A section is
/// one click away from any other, so nobody goes back to a list to reach the next. Back (and Esc) leaves
/// for the Imps, always. What needs attention is said where it is fixed: a mark on the section in the
/// rail and a notice at the top of its page. A map node or a tool's link selects a section and lights a row.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter

    private var section: SettingsGroup { router.settingsSection }

    var body: some View {
        let attention = SettingsMap.attention(SettingsNodes.nodes(for: model))
        VStack(spacing: 0) {
            TopBar(back: { router.goHome() }) {
                Text("settings.title")
                    .font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .accessibilityAddTraits(.isHeader)
            } trailing: {
                Text(verbatim: "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(Typeface.small).foregroundStyle(Tone.faint)
                    .cornerLabel(.trailing, bar: Metrics.barHeight)
            }
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    rail(compact: proxy.size.width < CGFloat(Behavior.narrowWindowPoints),
                         marked: Set(SettingsGroup.allCases.filter { SettingsMap.marked(attention).contains(.settings($0)) }))
                    ZStack {
                        SettingsPage {
                            AttentionNotice(attention.filter { $0.destination == .settings(section) }.map { AttentionNotice.Line($0) })
                            page
                        }
                        .id(section)
                        .transition(.opacity)
                    }
                    .impAnimation(ImpDesign.Motion.scene, value: section)
                    .environment(\.highlightedSetting, router.highlightedSetting)
                }
            }
        }
    }

    private func rail(compact: Bool, marked: Set<SettingsGroup>) -> some View {
        let items = SettingsGroup.allCases.map { item in
            SectionItem(id: item, title: item.title, symbol: item.symbol, needsAttention: marked.contains(item))
        }
        return ScrollView(.vertical, showsIndicators: false) {
            SectionRail("settings.title", items: items, selection: $router.settingsSection, axis: .vertical, compact: compact)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, Spacing.medium)
                .padding(.top, Spacing.hairline)
                .padding(.bottom, Spacing.page)
        }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .app: AppPane(model: model, router: router)
        case .bubble: BubblePane(model: model)
        case .talking: TalkingPane(model: model)
        case .brains: BrainsPane(model: model)
        case .sharing: SharingPane(model: model)
        case .privacy: PermissionsPage(model: model)
        case .backup: BackupPane(model: model, router: router)
        }
    }
}
