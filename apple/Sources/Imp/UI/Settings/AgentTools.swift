import ImpDesign
import ImpKit
import SwiftUI

/// The pictures of the actions every section header shares, so the same action looks the same everywhere.
enum SectionAction {
    /// What the Imp may do by itself in a section (its built-in tools there).
    static let agent = "wand.and.sparkles"
    /// Adding one: a new trigger, animation or tool.
    static let add = "plus"
    /// Adding a kit from a file, a link or the clipboard.
    static let importKit = "square.and.arrow.down"
}

/// "Import kit…" in a section's header: the same picture and words in Animations, Triggers and Tools.
/// With no Imp (Sharing) what it adds is for every Imp to begin with.
struct ImportKitButton: View {
    let imp: UUID?

    var body: some View {
        HoverIconButton(systemName: SectionAction.importKit, help: "Import kit…") {
            HomeWindow.shared.router.kitFlow = KitFlow(imp: imp, forEveryImp: imp == nil)
        }
    }
}

/// The header button of a section that opens what the Imp may do there by itself: the built-in tools of
/// that section, each with a switch. The same picture in every section.
struct AgentToolsButton: View {
    let model: AppModel
    @Binding var imp: ImpProfile
    let groups: [ImpToolGroup]
    @State private var open = false
    @Environment(\.impTint) private var tint

    var body: some View {
        let off = groups.allSatisfy { !imp.uses($0) }
        HoverIconButton(systemName: SectionAction.agent, help: LocalizedStringKey(words("agent.button", imp.callName)),
                        tint: off ? Tone.muted : tint) { open = true }
            .accessibilityValue(Text(off ? "agent.off" : "agent.on"))
            .accessibilityIdentifier("agent.tools")
            .sheet(isPresented: $open) {
                AgentToolsSheet(model: model, imp: $imp, groups: groups)
                    .environment(\.impTint, tint)
                    .tint(tint)
            }
    }
}

/// What the Imp may do by itself in one section: each group with its switch, and each of its tools with
/// one. A tool that is off is never offered to the model. Changes apply at once, as on the page, and Cancel
/// puts back the switches as they were when the sheet opened.
struct AgentToolsSheet: View {
    let model: AppModel?
    @Binding var imp: ImpProfile
    let groups: [ImpToolGroup]
    @Environment(\.dismiss) private var dismiss
    /// The Imp as it was when the sheet opened, for Cancel.
    @State private var before: ImpProfile?

    var body: some View {
        SheetScaffold(icon: SectionAction.agent, title: LocalizedStringKey(words("agent.title", imp.callName)), info: "agent.help",
                      cancel: { if let before { imp = before }; dismiss() }) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(groups) { group in groupCard(group) }
            }
        } footer: {
            Button("common.done") { dismiss() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { if before == nil { before = imp } }
    }

    private func groupCard(_ group: ImpToolGroup) -> some View {
        let tools = ToolRegistry.tools(in: group)
        let on = imp.uses(group)
        return VStack(alignment: .leading, spacing: Spacing.snug) {
            switchRow(title: group.title, icon: group.symbol, info: group.summary, font: Typeface.cardTitle,
                      isOn: Binding(get: { imp.uses(group) }, set: { imp.setUses(group, $0) }), edit: nil)
            // A group of one tool is that tool: its switch is enough.
            if tools.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools) { tool in
                        switchRow(title: tool.title.isEmpty ? tool.name : tool.title, icon: nil, info: nil, font: Typeface.body,
                                  isOn: Binding(get: { imp.uses(tool: tool.id) }, set: { imp.setUses(tool: tool.id, $0) }),
                                  edit: model.map { model in { ToolTextButton(imp: $imp, model: model, tool: tool, symbol: group.symbol) } })
                    }
                }
                .padding(.leading, Spacing.wide)
                .opacity(on ? 1 : Opacity.disabled)
                .disabled(!on)
            }
            if group == .computer, on { ComputerPermissions() }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.card))
    }

    private func switchRow(title: String, icon: String?, info: String?, font: Font, isOn: Binding<Bool>,
                           edit: (() -> ToolTextButton)?) -> some View {
        HStack(spacing: Spacing.small) {
            if let icon {
                Image(systemName: icon).font(.icon(.large)).foregroundStyle(Tone.muted)
                    .frame(width: Sizing.mark).accessibilityHidden(true)
            }
            Text(verbatim: title).font(font).foregroundStyle(Tone.text).lineLimit(2)
            if let info { InfoTip(verbatim: info) }
            Spacer(minLength: Spacing.small)
            if let edit { edit() }
            Toggle(isOn: isOn) { Text(verbatim: title) }
                .labelsHidden().toggleStyle(.impSwitchBare)
                .accessibilityLabel(Text(verbatim: title))
        }
        .frame(minHeight: Sizing.hit)
    }
}

/// What computer control still needs from macOS, with the buttons to grant it.
struct ComputerPermissions: View {
    var body: some View {
        let status = SystemStatus.shared
        let missing = Permission.computerControl.filter { !status.isGranted($0) }
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if missing.isEmpty {
                StatusText(text: "Permissions granted", symbol: "checkmark.circle.fill", color: Tone.good)
            } else {
                ForEach(missing) { p in
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warnText).font(.icon(.small))
                        Text("\(p.title) is off").font(Typeface.small).foregroundStyle(Tone.text)
                        Spacer(minLength: Spacing.small)
                        Button("Allow…") { p.request() }.buttonStyle(.imp(.primary, small: true))
                    }
                }
            }
        }
    }
}
