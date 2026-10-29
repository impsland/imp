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
                case .me:
                    LooksTab(imp: imp)
                    ShareCard(model: model, id: id)
                    GoodbyeCard(model: model, router: router, id: id)
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

/// Sending this Imp to a friend, or saving it to move to another Mac.
private struct ShareCard: View {
    @Bindable var model: AppModel
    let id: UUID

    private var name: String { model.profile(id).map { $0.name.isEmpty ? "this Imp" : $0.name } ?? "this Imp" }

    var body: some View {
        Card("Share", icon: "square.and.arrow.up") {
            Row("Share \(name)", info: "Copies \(name) as a kit: looks, personality, instructions, model and service address, tools, triggers and the tools it borrows. Whoever opens it sees what's in it first. Chats and API keys are never included.") {
                ShareKitButton(kit: ImpExport.kit([id], model: model, name: name), help: "Share \(name) as a kit")
            }
            CardDivider()
            Row("Export \(name)…", info: "Saves \(name) as a .json file you can keep as a backup or open with Import on another Mac. You can include its chats. API keys are never saved.") {
                Button { ImpExport.save([id], model: model, name: name, fileName: name) } label: { Label("Export…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }
    }
}

/// Removing this Imp for good, at the foot of its Looks page (the stage's menu has it too).
private struct GoodbyeCard: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let id: UUID
    @State private var confirming = false

    private var name: String { model.profile(id).map { $0.name.isEmpty ? "this Imp" : $0.name } ?? "this Imp" }
    private var isLast: Bool { model.prefs.imps.count <= 1 }

    var body: some View {
        Card("Goodbye", icon: "hand.wave.fill") {
            Row("Say goodbye to \(name)", info: isLast
                ? "The last Imp can't leave. Hatch another first, or start over from All Imps › Manners."
                : "Its looks, brain settings, tools, folder, chats and triggers go with it.") {
                Button(role: .destructive) { confirming = true } label: { Label("Say Goodbye…", systemImage: "trash") }
                    .buttonStyle(.imp(.destructive, small: true))
                    .disabled(isLast)
                    .help(isLast ? "The last Imp stays" : "Remove \(name) for good")
            }
        }
        .confirmationDialog("Say goodbye to \(name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Say Goodbye", role: .destructive) {
                guard let next = model.sayGoodbye(id) else { return }
                router.select(next)
                router.goHome()
            }
        } message: {
            Text("Its looks, brain settings, tools, folder and shortcuts go with it. This can't be undone.")
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
        .help(active ? "Out on your desktop: its triggers and tools work" : "At home in this window: its triggers wait until you let it out")
    }
}

/// The face of an Imp in its colour, for still portraits.
func impFace(hue: Double, mood: Mood = .idle) -> Face {
    var f = Face.settled(mood)
    f.hue = hue
    return f
}
