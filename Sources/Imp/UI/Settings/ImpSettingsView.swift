import ImpKit
import SwiftUI

/// One Imp's settings: the title bar (back beside the traffic lights, the Imp in the middle),
/// a full-width tab bar, and a short page of cards.
struct ImpSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let id: UUID

    /// Edits this Imp's profile in place.
    private var imp: Binding<ImpProfile> {
        Binding(get: { model.profile(id) ?? .imp },
                set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i] = new } })
    }

    var body: some View {
        let profile = imp.wrappedValue
        VStack(spacing: 0) {
            TopBar(back: router.goHome) {
                HStack(spacing: 8) {
                    portrait(profile).frame(width: 24, height: 24)
                    Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(Dungeon.cream)
                        .lineLimit(1)
                }
            } trailing: {
                ActiveBadge(active: profile.isActive)
            }
            SegmentedTabs(tabs: ImpTab.allCases, selection: $router.impTab, title: \.title, icon: \.icon,
                          badge: { $0 == .brain && !model.isReady(id) })
                .padding(.horizontal, Metrics.pagePadding)
                .frame(maxWidth: Metrics.column)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SettingsPage {
                switch router.impTab {
                case .me: LooksTab(imp: imp)
                case .brain: BrainTab(model: model, imp: imp)
                case .tools: ToolsTab(model: model, imp: imp)
                case .shortcuts: ShortcutsTab(model: model, id: id)
                }
            }
            .id(router.impTab)
            .transition(.opacity)
        }
        .environment(\.impTint, Color.imp(profile.hue))
        .tint(Color.imp(profile.hue))
    }

    /// Still, unless it's acting something out (like finding its favourite colour).
    @ViewBuilder private func portrait(_ profile: ImpProfile) -> some View {
        if let performance = model.performances[id] {
            StageImp(hue: profile.hue, mood: .happy, performance: performance, clock: BodyClock(profile.id))
        } else {
            ImpPortrait(face: impFace(hue: profile.hue, mood: .happy), shadow: false)
        }
    }
}

/// Whether the Imp is out on the desktop or waiting at home, as a small chip.
private struct ActiveBadge: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? Color.green : Dungeon.muted.opacity(0.6)).frame(width: 6, height: 6)
            Text(active ? "Out" : "At home").font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Dungeon.muted)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(Dungeon.card))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
        .help(active ? "Out on your desktop: its shortcuts and tools work" : "At home in this window: its shortcuts wait until you let it out")
    }
}

/// The face of an Imp in its colour, for still portraits.
func impFace(hue: Double, mood: Mood = .idle) -> Face {
    var f = Face.settled(mood)
    f.hue = hue
    return f
}
