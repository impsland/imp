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
    @State private var slug: String
    @State private var summary = ""
    @State private var tags = ""
    @State private var state: ActionState = .idle
    @State private var notice: ImpNotice?

    init(context: PublishContext, kit: Kit) {
        self.context = context
        self.kit = kit
        _slug = State(initialValue: DenPublish.suggestedSlug(for: kit))
    }

    private var server: DenServer? { DenServer(context.model.prefs.den) }
    private var canPublish: Bool {
        server != nil && state != .working && !DenName.slug(slug).isEmpty && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SheetScaffold(icon: "square.and.arrow.up.fill", title: "Publish to the Den",
                      info: "Anyone can add it. Chats, memory and keys are never included.") {
            if server == nil {
                DenNeeded()
            }
            field("Name in the Den", info: "den.help.slug", text: $slug, prompt: "my-package", mono: true)
            field("What is it, in a sentence", info: "den.help.summary", text: $summary, prompt: "A short wave hello")
            field("Tags (separated by commas)", info: "den.help.tags", text: $tags, prompt: "friendly, desk")
            VStack(alignment: .leading, spacing: Spacing.snug) {
                SectionHeader("What people will see it can do", info: "den.help.public",
                              font: Typeface.caption, color: Tone.muted, minHeight: nil)
                let lines = DenPublish.publicKit(kit).permissions.lines
                if lines.isEmpty {
                    Text("Only looks and text. No tools or commands.").font(Typeface.body).foregroundStyle(Tone.text)
                }
                ForEach(lines) { line in
                    Text(verbatim: "• " + line.text).font(Typeface.body).foregroundStyle(Tone.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Button { Task { await publish() } } label: { StatefulLabel("Publish", symbol: "arrow.up.circle", state: state) }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!canPublish)
                .impActionState($state)
        }
        .impNotice($notice)
    }

    private func field(_ title: LocalizedStringKey, info: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            SectionHeader(title, info: info, font: Typeface.caption, color: Tone.muted, minHeight: nil)
            TextField(title, text: text, prompt: Text(prompt)).impField(mono: mono).autocorrectionDisabled()
        }
    }

    private func publish() async {
        guard let server, let profile = context.model.profile(context.imp) else { return }
        state = .working
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
            state = .done
            notice = .success(String(localized: "Published: \(client.page(of: id).absoluteString)"))
        } catch {
            state = .failed
            notice = .error(error.localizedDescription)
        }
    }
}
