import ImpDesign
import ImpKit
import SwiftUI

/// The Tools panel: the MCP servers this Imp can use. "Add tools" is a section-level secondary button; inside a
/// server, "Add a header" is a small quiet button at the end of its headers.
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
            HStack(spacing: 0) {
                Text("tools.mcp").font(Typeface.label).foregroundStyle(Tone.text).accessibilityAddTraits(.isHeader)
                InfoTip("tools.help.mcp")
                Spacer(minLength: 0)
            }
            ForEach($draft.servers) { $server in
                serverCard($server)
            }
            Button { addServer() } label: { Label("tools.add", systemImage: "plus") }
                .buttonStyle(.secondary)
                .disabled(draft.servers.count >= PocketImp.maxServers)
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
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let problem { IssueBadge(text: problem) }
                    }
                }
                if !value.headers.isEmpty {
                    Text("tools.headers").font(Typeface.caption).foregroundStyle(Tone.muted)
                }
                ForEach(server.headers) { $header in
                    let kept = value.hostKept && header.savedName != nil
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        HStack(spacing: Spacing.small) {
                            TextField("tools.header_name", text: $header.name, prompt: Text(verbatim: "Authorization"))
                                .impField(mono: true)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { removeHeader(header.id, from: server) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.quiet)
                                .accessibilityLabel(Text("tools.remove_header"))
                        }
                        SecureField("tools.header_value", text: $header.value, prompt: kept ? Text("tools.header_saved") : Text(verbatim: "Bearer …"))
                            .impField(mono: true)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .id(header.id)
                }
                Button { addHeader(server) } label: { Label("tools.header_add", systemImage: "plus") }
                    .buttonStyle(.imp(.quiet, small: true))
                    .disabled(value.headers.count >= PocketServer.maxHeaders)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.card))
        .id(value.id)
    }
}
