import ImpDesign
import ImpKit
import SwiftUI

/// The frame of every Devices sheet: the picture, name, status and action icons in the header, the page, and the footer.
/// Switches act at once. Done keeps them and Cancel puts them back (`DeviceEdits`).
struct DeviceSheetShell<Actions: View, Page: View>: View {
    let model: AppModel
    let icon: String
    let title: String
    /// How the thing stands: the one pill in the header.
    var status: DeviceStatus?
    @ViewBuilder var actions: Actions
    @ViewBuilder var page: Page
    @State private var edits: DeviceEdits
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, icon: String, title: String, status: DeviceStatus? = nil,
         @ViewBuilder actions: () -> Actions, @ViewBuilder page: () -> Page) {
        self.model = model
        self.icon = icon
        self.title = title
        self.status = status
        self.actions = actions()
        self.page = page()
        _edits = State(initialValue: DeviceEdits(model))
    }

    var body: some View {
        SheetScaffold(icon: icon, title: LocalizedStringKey(title), cancel: { edits.restore(model); dismiss() }, accessory: {
            if let status { StatusPill(status: status) }
            actions
        }, content: {
            page
        }, footer: {
            Button { dismiss() } label: { FitLabel("common.done", systemImage: "checkmark") }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        })
    }
}

extension DeviceSheetShell where Actions == EmptyView {
    init(model: AppModel, icon: String, title: String, status: DeviceStatus? = nil, @ViewBuilder page: () -> Page) {
        self.init(model: model, icon: icon, title: title, status: status, actions: { EmptyView() }, page: page)
    }
}

/// What a press on the canvas opens: a sheet about one device, Imp or line. Its pages are in the `…Page` files, all
/// in one compact layout: the header has the picture, the name, one status pill and the actions as icon buttons (link,
/// send home, settings, forget). The page is chips that fill the width and cards of switches, with no row of its own for
/// a single button. Explanations are tooltips, not text. A chip that leads to another thing swaps the sheet. Forgetting
/// asks first.
struct DeviceSheet: View {
    let model: AppModel
    let router: HomeRouter
    let map: DeviceMap
    let selection: DeviceSelection
    /// Shows another sheet in place of this one.
    let swap: (DevicesSheet) -> Void
    @State private var forgetting: DeviceLink.Peer?
    @State private var forgettingEveryone = false

    var body: some View {
        let ctx = DeviceContext(model: model, router: router, map: map, select: { if let next = $0 { swap(.opening(next)) } },
                                link: { swap(.link) }, forget: { forgetting = $0 }, forgetEveryone: { forgettingEveryone = true },
                                hop: { swap(.hop) })
        let head = head(ctx)
        DeviceSheetShell(model: model, icon: head.icon, title: head.title, status: status(ctx), actions: { actions(ctx) }, page: {
            page(ctx)
        })
        .confirmationDialog(forgetting.map { String(localized: "Forget \($0.name)?") } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { peer in
            Button("Forget \(peer.name)", role: .destructive) { model.link.forget(peer.id) }
        } message: { _ in
            Text("Imps it holds come back to your desktop. To link again, one of you shows a new code.")
        }
        .confirmationDialog("Forget every device?", isPresented: $forgettingEveryone, titleVisibility: .visible) {
            Button("Forget Everyone", role: .destructive) { model.link.forgetEveryone() }
        } message: {
            Text("Imps on other devices come back to your desktop. The old codes stop working; link again with a new one.")
        }
    }

    /// The picture and the name in the sheet's header.
    private func head(_ ctx: DeviceContext) -> (icon: String, title: String) {
        switch selection {
        case .node(let id):
            guard let node = map.node(id) else { return ("questionmark", String(localized: "devices.unknown_device")) }
            return (node.symbol, node.title)
        case .imp(let id, let node):
            let name = map.residents(of: node).first { $0.id == id }?.name ?? ""
            return ("person.fill", name)
        case .channel(let id):
            guard let channel = map.channels.first(where: { $0.id == id }) else { return ("questionmark", String(localized: "devices.unknown_device")) }
            return (channel.path == .relay ? "arrow.triangle.swap" : "wifi",
                    words("devices.channel.title", ctx.name(of: channel.from), ctx.name(of: channel.to)))
        }
    }

    /// The one pill in the header.
    private func status(_ ctx: DeviceContext) -> DeviceStatus? {
        switch selection {
        case .node(let id): map.node(id).map(map.status(of:))
        case .imp(let id, let node):
            if map.imp(id) != nil {
                node == ctx.thisMac ? DeviceStatus(word: String(localized: "devices.status.here"), tone: Tone.good)
                    : DeviceStatus(word: String(localized: "devices.state.offline"), tone: Tone.warnText)
            } else {
                node == ctx.thisMac ? DeviceStatus(word: String(localized: "devices.status.visiting"), tone: Tone.muted)
                    : DeviceStatus(word: map.title(of: node), tone: Tone.muted)
            }
        case .channel(let id): map.channels.first { $0.id == id }.map(map.status(of:))
        }
    }

    /// The icon buttons in the header.
    @ViewBuilder private func actions(_ ctx: DeviceContext) -> some View {
        switch selection {
        case .node(let id):
            if let node = map.node(id) {
                switch node.kind {
                case .thisMac: ThisMacActions(ctx: ctx)
                case .server: EmptyView()
                case .mac, .phone: LinkedDeviceActions(ctx: ctx, node: node)
                }
            }
        case .imp(let id, let node):
            if let contact = map.residents(of: node).first(where: { $0.id == id }) {
                if let entry = map.imp(id), model.profile(id) != nil {
                    ImpActions(ctx: ctx, entry: entry)
                } else {
                    VisitorActions(ctx: ctx, contact: contact)
                }
            }
        case .channel: EmptyView()
        }
    }

    @ViewBuilder private func page(_ ctx: DeviceContext) -> some View {
        switch selection {
        case .node(let id):
            if let node = map.node(id) {
                switch node.kind {
                case .thisMac: ThisMacPage(ctx: ctx, node: node)
                case .server: EmptyView()  // the Hop has its own sheet (`HopSheet`)
                case .mac, .phone: LinkedDevicePage(ctx: ctx, node: node)
                }
            }
        case .imp(let id, let node):
            if let contact = map.residents(of: node).first(where: { $0.id == id }) {
                if let entry = map.imp(id), model.profile(id) != nil {
                    ImpPage(ctx: ctx, entry: entry)
                } else {
                    VisitorPage(ctx: ctx, contact: contact)
                }
            }
        case .channel(let id):
            if let channel = map.channels.first(where: { $0.id == id }) { ChannelPage(ctx: ctx, channel: channel) }
        }
    }
}
