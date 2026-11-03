import ImpDesign
import ImpKit
import SwiftUI

/// Which Imp is publishing, and from which model: set by an Imp's settings so every Share button
/// inside it can also offer the Den.
struct PublishContext {
    let model: AppModel
    let imp: UUID
}

extension EnvironmentValues {
    @Entry var publishContext: PublishContext?
}

/// Publishing a kit to the user's Den as one of an Imp's packages. It says what will be public and
/// what is left out, and nothing leaves this Mac before Publish.
struct DenPublishSheet: View {
    let context: PublishContext
    let kit: Kit
    @Environment(\.dismiss) private var dismiss
    @State private var slug: String
    @State private var summary = ""
    @State private var tags = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var published: URL?

    init(context: PublishContext, kit: Kit) {
        self.context = context
        self.kit = kit
        _slug = State(initialValue: DenPublish.suggestedSlug(for: kit))
    }

    private var server: ImpServer? { ImpServer(context.model.prefs.server) }
    private var canPublish: Bool {
        server != nil && !isWorking && !DenName.slug(slug).isEmpty && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SheetScaffold(icon: "square.and.arrow.up.fill", title: "Publish to the Den",
                      info: "Anyone who can reach the Den can read this and add it. Chats, memory, API keys and the model settings are never included.",
                      width: 520) {
            if server == nil {
                StatusText(text: "Set a server in Settings under Devices first.", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            field("Name in the Den", text: $slug, prompt: "my-package", mono: true)
            field("What is it, in a sentence", text: $summary, prompt: "A short wave hello")
            field("Tags (separated by commas)", text: $tags, prompt: "friendly, desk")
            VStack(alignment: .leading, spacing: 5) {
                Text("What people will see it can do").font(.system(size: 12, weight: .medium)).foregroundStyle(Dungeon.muted)
                let lines = DenPublish.publicKit(kit).permissions.lines
                if lines.isEmpty {
                    Text("Only looks and text. No tools or commands.").font(.system(size: 12)).foregroundStyle(Dungeon.cream.opacity(0.9))
                }
                ForEach(lines) { line in
                    Text(verbatim: "• " + line.text).font(.system(size: 12)).foregroundStyle(Dungeon.cream.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let published {
                StatusText(text: "Published: \(published.absoluteString)", symbol: "checkmark.circle.fill", color: .green)
            }
            if let error { StatusText(text: LocalizedStringKey(error), symbol: "exclamationmark.triangle.fill", color: .orange) }
        } footer: {
            Spacer()
            Button(published == nil ? "Cancel" : "Done", role: .cancel) { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button { Task { await publish() } } label: { Label("Publish", systemImage: "arrow.up.circle") }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!canPublish)
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Dungeon.muted)
            TextField(String(prompt), text: text).impField(mono: mono).autocorrectionDisabled()
        }
    }

    private func publish() async {
        guard let server, let profile = context.model.profile(context.imp) else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            var shared = kit
            if shared.app == nil { shared.app = AppInfo.version }
            let text = try DenPublish.text(of: shared)
            let client = DenClient(server: server)
            let accounts = DenAccounts(inKeychain: context.model.prefs.keysInKeychain)
            let login = try await accounts.ensure(on: server, imp: context.imp, name: profile.name, client: client)
            guard let id = DenItemID(handle: login.handle, slug: DenName.slug(slug)) else { throw DenError(status: 0, title: String(localized: "That name can't be used.")) }
            let words = DenPublish.tags(tags.split(separator: ",").map(String.init))
            _ = try await client.put(id, summary: String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DenPublish.maxSummary)),
                                     tags: words, kit: text, token: login.token)
            published = client.page(of: id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
