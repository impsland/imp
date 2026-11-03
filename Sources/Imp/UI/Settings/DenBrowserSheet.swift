import ImpDesign
import ImpKit
import SwiftUI

/// Looking through the Den: search what others shared (Imps, animations, triggers, tools, kits) and
/// open one for review. What comes back is only data to show. Nothing is installed here: Review
/// downloads the package, checks its checksum and opens the usual review, where the user decides.
@MainActor @Observable
final class DenBrowser {
    var text = ""
    var kind: String?
    var sort = "popular"
    var items: [DenItem] = []
    var nextCursor: String?
    var isLoading = false
    var error: String?
    var searched = false

    func client(_ prefs: ImpPreferences) -> DenClient? { ImpServer(prefs.server).map { DenClient(server: $0) } }

    func search(_ prefs: ImpPreferences, more: Bool = false) async {
        guard let client = client(prefs) else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let query = DenQuery(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, sort: sort, limit: 20, cursor: more ? nextCursor : nil)
            let page = try await client.items(query)
            items = more ? items + page.items : page.items
            nextCursor = page.nextCursor
            searched = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DenBrowserSheet: View {
    let model: AppModel
    let flow: KitFlow
    @Bindable var router: HomeRouter
    @State private var browser = DenBrowser()

    private var server: ImpServer? { ImpServer(model.prefs.server) }

    var body: some View {
        SheetScaffold(icon: "books.vertical.fill", title: "Browse the Den",
                      info: "The Den is where people share Imps, animations, triggers and tools. Search it, pick something and you'll see what it can do before anything is added.",
                      width: 560) {
            serverRow
            if server != nil {
                searchRow
                results
            }
            if let error = browser.error { StatusText(text: LocalizedStringKey(error), symbol: "exclamationmark.triangle.fill", color: .orange) }
        } footer: {
            Button("Back") { flow.browsing = false }.buttonStyle(.quiet)
            Spacer()
            SheetCancelButton { router.kitFlow = nil }
        }
        .task(id: model.prefs.server) { if server != nil { await browser.search(model.prefs) } }
    }

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Den server").font(.system(size: 12, weight: .medium)).foregroundStyle(Dungeon.muted)
            TextField(String("imp.example.org"), text: Binding(get: { model.prefs.server }, set: { model.prefs.server = $0 }))
                .impField(mono: true).autocorrectionDisabled()
            if model.prefs.server.isEmpty {
                Text("Enter the address of a Den to search it. It's the same server as in Settings under Devices.")
                    .font(.system(size: 12)).foregroundStyle(Dungeon.muted)
            } else if server == nil {
                StatusText(text: "That isn't a server address. Use a host name such as imp.example.org.", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $browser.text).impField().onSubmit { run() }
            CompactMenu(verbatim: kindTitle(browser.kind), symbol: "line.3.horizontal.decrease", maxWidth: 130) {
                Button("Everything") { browser.kind = nil; run() }
                Divider()
                ForEach(DenQuery.kinds, id: \.self) { kind in Button(kindTitle(kind)) { browser.kind = kind; run() } }
            }
            CompactMenu(verbatim: browser.sort == "new" ? String(localized: "Newest") : String(localized: "Popular"), symbol: "arrow.up.arrow.down", maxWidth: 110) {
                Button("Popular") { browser.sort = "popular"; run() }
                Button("Newest") { browser.sort = "new"; run() }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if browser.isLoading && browser.items.isEmpty {
            ProgressView().controlSize(.regular).frame(maxWidth: .infinity, minHeight: 80)
        } else if browser.items.isEmpty && browser.searched {
            Text("Nothing found.").font(.system(size: 13)).foregroundStyle(Dungeon.muted).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ForEach(browser.items, id: \.id) { item in row(item) }
            if browser.nextCursor != nil {
                Button("Show more") { Task { await browser.search(model.prefs, more: true) } }
                    .buttonStyle(.imp(.secondary, small: true)).disabled(browser.isLoading)
            }
        }
    }

    private func row(_ item: DenItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: item.name.isEmpty ? item.slug : item.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                if !item.summary.isEmpty {
                    Text(verbatim: item.summary).font(.system(size: 12)).foregroundStyle(Dungeon.cream.opacity(0.85))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    Badge(verbatim: kindTitle(item.kind), symbol: "shippingbox.fill")
                    Badge(verbatim: item.handle, symbol: "person.fill")
                    if item.installs > 0 { Badge("\(item.installs) installs", symbol: "arrow.down.circle") }
                    if item.runsPrograms { Badge("Runs commands", symbol: "terminal.fill", color: .orange) }
                }
            }
            Spacer(minLength: 8)
            Button("Review") {
                guard let id = item.id, let client = browser.client(model.prefs) else { return }
                Task { await flow.read(den: id, client: client, model: model) }
            }
            .buttonStyle(.imp(.secondary, small: true)).disabled(item.id == nil)
            .help("Downloads it and shows what it does. Nothing is added yet.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Dungeon.card))
    }

    private func run() { Task { await browser.search(model.prefs) } }

    private func kindTitle(_ kind: String?) -> String {
        switch kind {
        case "imp": String(localized: "Imps")
        case "animation": String(localized: "Animations")
        case "trigger": String(localized: "Triggers")
        case "tool": String(localized: "Tools")
        case "kit": String(localized: "Kits")
        default: String(localized: "Everything")
        }
    }
}
