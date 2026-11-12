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

    func client(_ prefs: ImpPreferences) -> DenClient? { DenServer(prefs.den).map { DenClient(server: $0) } }

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
    @State private var browser: DenBrowser

    init(model: AppModel, flow: KitFlow, router: HomeRouter) {
        self.model = model
        self.flow = flow
        self.router = router
        let browser = DenBrowser()
        browser.kind = flow.browseKind
        _browser = State(initialValue: browser)
    }

    private var server: DenServer? { DenServer(model.prefs.den) }

    var body: some View {
        SheetScaffold(icon: "books.vertical.fill", title: "Browse the Den",
                      info: "Where people share Imps, animations, triggers and tools.") {
            serverRow
            if server != nil {
                searchRow
                results
            }
            if let error = browser.error { StatusText(text: LocalizedStringKey(error), symbol: "exclamationmark.triangle.fill", color: Tone.danger) }
        } footer: {
            Button("Back") { flow.browsing = false }.buttonStyle(.quiet)
        }
        .task(id: model.prefs.den) { if server != nil { await browser.search(model.prefs) } }
    }

    /// The Den in the same card as on the Sharing page, and why browsing waits for it.
    private var serverRow: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            ServerCard(kind: .den, text: Binding(get: { model.prefs.den }, set: { model.prefs.den = $0 }))
            if server == nil { DenNeeded() }
        }
    }

    private var searchRow: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            FieldRow("Search", info: "den.help.search") {
                TextField("Search", text: $browser.text).impField().onSubmit { run() }
            }
            FieldRow("Kind", info: "den.help.kind") {
                ImpPicker("Kind", selection: $browser.kind, options: [nil] + DenQuery.kinds.map(Optional.some),
                          symbol: "line.3.horizontal.decrease", title: kindTitle)
            }
            FieldRow("Sort", info: "den.help.sort") {
                ImpSegmented("Sort", selection: $browser.sort, options: ["popular", "new"],
                             title: { $0 == "new" ? String(localized: "Newest") : String(localized: "Popular") },
                             symbol: { $0 == "new" ? "clock" : "flame" })
            }
        }
        .onChange(of: browser.kind) { run() }
        .onChange(of: browser.sort) { run() }
    }

    @ViewBuilder private var results: some View {
        if browser.isLoading && browser.items.isEmpty {
            ProgressView().controlSize(.regular).frame(maxWidth: .infinity, minHeight: Sizing.hit * 3)
        } else if browser.items.isEmpty && browser.searched {
            Text("Nothing found.").font(Typeface.body).foregroundStyle(Tone.muted).frame(maxWidth: .infinity, minHeight: Sizing.hit * 2)
        } else {
            ForEach(browser.items, id: \.id) { item in row(item) }
            if browser.nextCursor != nil {
                Button { Task { await browser.search(model.prefs, more: true) } } label: { FitLabel("Show more", systemImage: "chevron.down") }
                    .buttonStyle(.imp(.secondary, small: true)).disabled(browser.isLoading)
            }
        }
    }

    private func row(_ item: DenItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text(verbatim: item.name.isEmpty ? item.slug : item.name)
                    .font(Typeface.cardTitle).lineLimit(1)
                if !item.summary.isEmpty {
                    Text(verbatim: item.summary).font(Typeface.body).foregroundStyle(Tone.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: Spacing.snug, lineSpacing: Spacing.snug) {
                    Badge(verbatim: kindTitle(item.kind), symbol: "shippingbox.fill")
                    Badge(verbatim: item.handle, symbol: "person.fill")
                    if item.installs > 0 { Badge("\(item.installs) installs", symbol: "arrow.down.circle") }
                    if item.runsPrograms { Badge("Runs commands", symbol: "terminal.fill", color: Tone.warnText) }
                }
            }
            Spacer(minLength: Spacing.small)
            Button {
                guard let id = item.id, let client = browser.client(model.prefs) else { return }
                Task { await flow.read(den: id, client: client, model: model) }
            } label: { FitLabel("Review", systemImage: "eye") }
            .buttonStyle(.imp(.secondary, small: true)).disabled(item.id == nil)
            .help("Downloads it and shows what it does. Nothing is added yet.")
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
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
