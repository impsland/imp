import ImpDesign
import ImpKit
import SwiftUI

/// The Tools panel: the MCP servers this Imp can use. "Add tools" sits in the section's header; inside a
/// server, "Add a header" is a plus in the header of its headers. No action is left alone under a list.
struct PocketToolsPanel: View {
    @Bindable var draft: PocketDraft
    let proxy: ScrollViewProxy
    /// The tool server asked to be removed, while its saved value is being confirmed.
    @Binding var removing: UUID?
    /// The tool servers shown open.
    @State private var openServers: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            // Add is an action on the list, so it sits in the list's header, as on the Mac.
            SectionHeader("tools.mcp", info: "tools.help.mcp", font: Typeface.label, minHeight: nil) {
                Button { addServer() } label: { FitLabel("tools.add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(draft.servers.count >= PocketImp.maxServers)
            }
            ForEach($draft.servers) { $server in
                serverCard($server)
            }
        }
    }

    private func reveal(_ id: some Hashable, anchor: UnitPoint) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 320))
            withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    private func addServer() {
        let server = ServerDraft()
        withImpAnimation(reduceMotion: reduceMotion) { draft.servers.append(server); openServers.insert(server.id) }
        reveal(server.id, anchor: .top)
    }

    private func addHeader(_ server: Binding<ServerDraft>) {
        let header = HeaderDraft()
        withImpAnimation(reduceMotion: reduceMotion) { server.wrappedValue.headers.append(header) }
        reveal(header.id, anchor: .center)
    }

    private func removeHeader(_ id: UUID, from server: Binding<ServerDraft>) {
        withImpAnimation(reduceMotion: reduceMotion) { server.wrappedValue.headers.removeAll { $0.id == id } }
    }

    private func remove(_ server: ServerDraft) {
        if (server.hostKept && server.holdsSecrets) || server.headers.contains(where: { !$0.value.isEmpty }) { removing = server.id }
        else { withImpAnimation(reduceMotion: reduceMotion) { draft.servers.removeAll { $0.id == server.id } } }
    }

    private func serverCard(_ server: Binding<ServerDraft>) -> some View {
        let value = server.wrappedValue
        let isOpen = openServers.contains(value.id)
        let title = value.name.trimmed.isEmpty ? (PocketDraft.host(value.url) ?? String(localized: "tools.new_server")) : value.name.trimmed
        let problem = draft.serverProblem(value)
        return VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: 0) {
                Button {
                    withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) {
                        if isOpen { openServers.remove(value.id) } else { openServers.insert(value.id) }
                    }
                } label: {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "chevron.right").font(.icon(.medium, weight: .bold)).foregroundStyle(Tone.muted)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                        // A dot and a word, never colour alone: it is ready or it needs a fix.
                        Circle().fill(problem == nil ? Tone.good : Tone.accent).frame(width: Spacing.small, height: Spacing.small)
                            .accessibilityHidden(true)
                        Text(title).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(2)
                        Spacer(minLength: Spacing.tight)
                    }
                    .frame(minHeight: Sizing.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(words(isOpen ? "tools.collapse" : "tools.expand", title))
                .accessibilityValue(problem ?? String(localized: "tools.mcp_connected"))
                Button { remove(value) } label: { Image(systemName: "trash") }
                    .buttonStyle(.destructive)
                    .accessibilityLabel(Text("tools.remove_server"))
            }
            if isOpen {
                Titled(title: "tools.server_name") {
                    TextField("tools.server_name", text: server.name, prompt: Text("tools.optional")).impField()
                }
                Titled(title: "firstrun.service.address") {
                    HStack(spacing: Spacing.tight) {
                        TextField("firstrun.service.address", text: server.url, prompt: Text(verbatim: "https://example.com/mcp"))
                            .impField(mono: true)
                            .codeEntry(.address)
                        if let problem { IssueBadge(text: problem) }
                    }
                }
                // The headers' own small header: their title, and Add on the trailing side.
                SectionHeader("tools.headers", font: Typeface.caption, color: Tone.muted, minHeight: nil) {
                    HoverIconButton(systemName: "plus", help: "tools.header_add") { addHeader(server) }
                        .disabled(value.headers.count >= PocketServer.maxHeaders)
                }
                ForEach(server.headers) { $header in
                    let kept = value.hostKept && header.savedName != nil
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        HStack(spacing: Spacing.small) {
                            TextField("tools.header_name", text: $header.name, prompt: Text(verbatim: "Authorization"))
                                .impField(mono: true)
                                .codeEntry()
                            Button { removeHeader(header.id, from: server) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.quiet)
                                .accessibilityLabel(Text("tools.remove_header"))
                        }
                        // The same keyboard as the header's name above it (see `SecretField`).
                        SecretField(title: "tools.header_value", text: $header.value, prompt: kept ? Text("tools.header_saved") : Text(verbatim: "Bearer …"))
                            .impField(mono: true)
                    }
                    .id(header.id)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.card))
        .id(value.id)
    }
}
