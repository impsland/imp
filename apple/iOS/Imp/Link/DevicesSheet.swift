import ImpDesign
import ImpKit
import SwiftUI

/// The iPhone's settings. The same model as the Mac: a bar with the sections always one tap away
/// under the title, and the chosen section below it in one scroll view. What needs attention is a mark
/// on its section and a notice at the top of that section. Sections are siblings, not levels, so there
/// is no Back, only Close.
struct DevicesSheet: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    /// Opens the Brain of one of this iPhone's Imps (its settings, at the Brain).
    var openBrain: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var section: PhoneSection
    @State private var forgetting: LinkDevice?
    @State private var forgettingEveryone = false
    @State private var scanning = false
    @State private var problem: String?

    /// `start` is the section to open on.
    init(hub: LinkHub, pocket: PocketRuntime, start: PhoneSection = .brains, openBrain: @escaping (UUID) -> Void = { _ in }) {
        self.hub = hub
        self.pocket = pocket
        self.openBrain = openBrain
        _section = State(initialValue: start)
    }

    private var nodes: [SettingsNode] { PhoneNodes.nodes(hub: hub, pocket: pocket) }

    private var attention: [AttentionItem] { SettingsMap.attention(nodes) }

    private var items: [SectionItem<PhoneSection>] {
        let marked = SettingsMap.attentionGroups(attention)
        return PhoneSection.allCases.map { item in
            SectionItem(id: item, title: item.title, symbol: item.symbol, needsAttention: marked.contains(item.group))
        }
    }

    var body: some View {
        VStack(spacing: Spacing.small) {
            SheetBar(close: { dismiss() }) {
                Text("settings.title").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .accessibilityAddTraits(.isHeader)
            }
            .sheetBarInsets()
            SectionRail("settings.title", items: items, selection: $section, axis: .horizontal)
            ScrollView {
                VStack(spacing: Spacing.medium) {
                    AttentionNotice(attention.filter { $0.group == section.group }.map(line))
                    content
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.small).padding(.bottom, Spacing.wide)
            }
            .scrollBounceBehavior(.basedOnSize)
            .dismissesKeyboard()
            .keyboardGap()
        }
        .impControls(tint: Tone.accent)
        .background(Tone.surface)
        .presentationBackground(Tone.surface)
        .impNoticeHost()
        .fullScreenCover(isPresented: $scanning) { LinkScanner(hub: hub, problem: $problem, scanning: $scanning) }
        .confirmationDialog(forgetting.map { words("phone.forget.title", $0.name) } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { device in
            Button(words("phone.forget.one.title", device.name), role: .destructive) { hub.forget(device.id) }
        } message: { _ in
            Text("phone.forget.message")
        }
        .confirmationDialog("phone.forget_all.title", isPresented: $forgettingEveryone, titleVisibility: .visible) {
            Button("phone.forget.everyone.title", role: .destructive) { hub.forgetEveryone() }
        } message: {
            Text("phone.forget_all.message")
        }
    }

    /// A problem, with its fix when the fix is elsewhere: an Imp without a Brain opens its Brain.
    private func line(_ item: AttentionItem) -> AttentionNotice.Line {
        guard case .noBrain(let imp) = item.reason, pocket.contains(imp.id) else { return AttentionNotice.Line(item) }
        return AttentionNotice.Line(item, fix: AttentionNotice.Fix("phone.brains.set_up", symbol: ImpSetting.brain.symbol) { openBrain(imp.id) })
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .brains: PhoneBrainsSection(pocket: pocket, openBrain: openBrain)
        case .devices:
            PhoneDevicesSection(hub: hub, pocket: pocket, scan: { scanning = true },
                                forget: { forgetting = $0 }, forgetAll: { forgettingEveryone = true })
        case .sharing: ServerCard(hub: hub, kind: .den)
        case .app: PhoneAppSection()
        }
    }
}

/// What the attention marks are worked out from: this iPhone and its Imps, the Brains they use, the servers and the linked devices.
enum PhoneNodes {
    @MainActor static func nodes(hub: LinkHub, pocket: PocketRuntime) -> [SettingsNode] {
        let asleep = pocket.imps.filter { !pocket.hasBrain($0.id) }.map { Sleeper(id: $0.id, name: $0.look.name) }
        var result = [SettingsNode(id: "me", kind: .thisDevice, name: hub.name, state: .ready,
                                   imps: pocket.looks.map(\.name), sleeping: asleep),
                      SettingsNode(id: "brains", kind: .brains, name: "",
                                   state: pocket.imps.contains { pocket.hasBrain($0.id) } ? .ready : .needsSetup),
                      SettingsNode(id: "den", kind: .den, name: "", state: SettingsMap.serverState(hub.den, .den)),
                      SettingsNode(id: "hop", kind: .hop, name: "", state: SettingsMap.serverState(hub.hop, .hop),
                                   isLocal: ServerKind.isOnThisDevice(hub.hop))]
        for link in hub.links {
            let device = link.device
            let seen = hub.isConnected(device.id)
            result.append(SettingsNode(id: device.id.uuidString, kind: device.kind == .mac ? .desktop : .phone, name: device.name,
                                       state: seen ? .ready : .offline,
                                       imps: pocket.looks.filter { hub.holders[$0.id] == device.id }.map(\.name),
                                       seen: seen, toolsHere: seen && hub.isTrusted(device.id),
                                       via: hub.viaHop.contains(device.id) ? HopServer(hub.hop)?.host : nil))
        }
        return result
    }
}
