import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// What the Imp may reach on this Mac: running commands, its senses (the Mac's state and the browser
/// page) and computer control. Each is one switch. The single tools are behind the section's agent button.
struct ComputerPanel: View {
    let model: AppModel
    @Binding var imp: ImpProfile

    var body: some View {
        PanelSection("computer.access", icon: "desktopcomputer", info: "computer.help.access",
                     accessory: { AgentToolsButton(model: model, imp: $imp, groups: [.senses, .computer]) }) {
            commands
            Row("Senses", icon: ImpToolGroup.senses.symbol, info: "computer.help.senses") { groupSwitch(.senses) }
            browser
            Row("Computer control", icon: ImpToolGroup.computer.symbol, info: "computer.help.control") { groupSwitch(.computer) }
                .settingAnchor(.computerControl)
            if imp.uses(.computer) { ComputerPermissions() }
        }
    }

    /// Running commands on this Mac (the shell) is one switch, not a list of tools.
    private var commands: some View {
        Row("Commands", icon: "terminal.fill", info: "Runs commands on your Mac with your permissions, without asking first.") {
            HStack(spacing: Spacing.small) {
                HoverIconButton(systemName: "folder", help: "Show \(imp.callName)'s folder. Commands start there.") {
                    let folder = Workspace.directory(for: imp.id)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Toggle(isOn: $imp.usesShell) { Text("Commands") }.labelsHidden().toggleStyle(.impSwitchBare)
            }
        }
        .settingAnchor(.computerCommands)
    }

    /// The browser extension: whether it is connected, and its folder to load it in a browser.
    private var browser: some View {
        let bridge = BrowserBridge.shared
        return Row("Browser", icon: "globe", info: "tools.help.browser") {
            HStack(spacing: Spacing.small) {
                if let page = bridge.page, bridge.isConnected {
                    StatusText(text: "Connected to \(page.browser)", symbol: "checkmark.circle.fill", color: Tone.good)
                } else if bridge.isConnected {
                    StatusText(text: "Connected", symbol: "checkmark.circle.fill", color: Tone.good)
                } else {
                    StatusText(text: "Not connected", symbol: "circle.dashed")
                }
                HoverIconButton(systemName: "folder", help: "Show the extension's folder") { ExtensionFolder.reveal() }
            }
        }
        .settingAnchor(.computerBrowser)
    }

    private func groupSwitch(_ group: ImpToolGroup) -> some View {
        Toggle(isOn: Binding(get: { imp.uses(group) }, set: { imp.setUses(group, $0) })) { Text(verbatim: group.title) }
            .labelsHidden().toggleStyle(.impSwitchBare)
            .accessibilityLabel(Text(verbatim: group.title))
    }
}
