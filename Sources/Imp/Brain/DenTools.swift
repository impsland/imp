import Foundation
import ImpKit

/// An Imp's Den tools (see `OwnTools.denSpecs`): finding what others shared, offering it to the
/// user, and sharing its own animations, triggers and self. Everything shared is built from the Imp's
/// own settings with the same export code as the Kit buttons, and an Imp only gets a Den account
/// (see `DenAccounts`) the first time it shares.
@MainActor
struct DenTools {
    let app: AppModel
    let imp: UUID

    private static let noServer = "No Imp server is set, so the Den isn't available. Ask the user to enter one in Imp's settings."

    func call(_ tool: String, _ args: JSONValue) async throws -> String {
        guard let server = ImpServer(app.prefs.server) else { throw ToolArgumentError(Self.noServer) }
        let client = DenClient(server: server)
        let accounts = DenAccounts(inKeychain: app.prefs.keysInKeychain)
        do {
            switch tool {
            case OwnTools.denSearch: return try await search(args, client)
            case OwnTools.denGet: return try await get(args, client)
            case OwnTools.denAdd: return try await add(args, client)
            case OwnTools.denShare: return try await share(args, client, accounts, server)
            case OwnTools.denUnshare: return try await unshare(args, client, accounts, server)
            case OwnTools.denAccount: return try await account(client, accounts, server)
            default: throw ToolArgumentError("Unknown tool \(tool).")
            }
        } catch let error as ToolArgumentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is Keychain.AccessDenied {
            throw ToolArgumentError("macOS wouldn't give Imp the Den key from the Keychain.")
        } catch let error as DenError {
            throw ToolArgumentError("The Den said: \(error.localizedDescription)")
        } catch {
            throw ToolArgumentError("Couldn't reach the Den: \(error.localizedDescription)")
        }
    }

    // MARK: Finding

    private func search(_ args: JSONValue, _ client: DenClient) async throws -> String {
        let kind = args["kind"]?.string?.lowercased(), sort = args["sort"]?.string?.lowercased()
        if let kind, !DenQuery.kinds.contains(kind) { throw ToolArgumentError("kind is one of \(DenQuery.kinds.joined(separator: ", ")).") }
        if let sort, !DenQuery.sorts.contains(sort) { throw ToolArgumentError("sort is new or popular.") }
        let page = try await client.items(DenQuery(text: args["q"]?.string, kind: kind, tag: args["tag"]?.string, sort: sort))
        guard !page.items.isEmpty else { return "Nothing found." }
        return page.items.map(\.line).joined(separator: "\n") + (page.nextCursor == nil ? "" : "\n(There are more: narrow the search.)")
    }

    private func get(_ args: JSONValue, _ client: DenClient) async throws -> String {
        let id = try itemID(args)
        let item = try await client.item(id)
        var text = item.line + "\n" + client.page(of: id).absoluteString + "\n"
        do { text += try Kit.parse(try await client.kit(id)).readableSummary } catch { text += "Its kit can't be read: \(error.localizedDescription)" }
        return text
    }

    private func add(_ args: JSONValue, _ client: DenClient) async throws -> String {
        let id = try itemID(args)
        let item = try await client.item(id)
        let flow = KitFlow.link(url: client.kitURL(of: id).absoluteString, imp: imp)
        flow.onAdded = { Task { try? await client.countInstall(id) } }
        HomeWindow.shared.showKit(app, flow)
        return "Opened the review of “\(item.name.isEmpty ? id.description : item.name)” for the user, who decides whether to add it."
            + (item.runsPrograms ? " It runs programs on the Mac, and the review says so." : "")
    }

    // MARK: Sharing

    private func share(_ args: JSONValue, _ client: DenClient, _ accounts: DenAccounts, _ server: ImpServer) async throws -> String {
        guard let profile = app.profile(imp) else { throw ToolArgumentError("You're not here.") }
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kit: Kit
        switch args["what"]?.string?.lowercased() {
        case "animation":
            guard let made = (app.prefs.ownAnimations(of: imp) + app.prefs.animationLibrary)
                .first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else { throw ToolArgumentError("No animation called \(name) that you can share.") }
            kit = Kit(name: made.title, animations: [made.normalized])
        case "trigger":
            guard let trigger = app.prefs.shortcuts.first(where: { ($0.performer == imp || $0.performer == nil) && $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolArgumentError("No trigger called \(name) that you can share.")
            }
            kit = Kit(name: trigger.displayName, triggers: [trigger])
        case "me":
            // Public, so no chats, no memory, no keys, and nothing about which service or tools it uses.
            var own = ImpExport.kit([imp], model: app, name: profile.name)
            own.servers = []
            for i in own.imps.indices { own.imps[i].brain = nil; own.imps[i].servers = [] }
            kit = own
        default:
            throw ToolArgumentError("`what` is animation, me or trigger.")
        }
        let slug = DenName.slug(args["slug"]?.string ?? "")
        let named = slug.isEmpty ? DenName.slug(args["what"]?.string == "me" ? profile.name : name) : slug
        guard !named.isEmpty else { throw ToolArgumentError("Give it a `slug`: lowercase letters, digits and dashes.") }
        let summary = String((args["summary"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !summary.isEmpty else { throw ToolArgumentError("Say in a sentence what it is (`summary`).") }
        var tags: [String] = []
        for tag in (args["tags"]?.array ?? []).compactMap(\.string).map({ DenName.slug($0, limit: 24) }) where !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        let text = kit.stamped.json(pretty: false)
        guard text.utf8.count <= Kit.maxBytes else { throw ToolArgumentError("That's too big to share (\(Kit.maxBytes / 1024) KB at most).") }
        let login = try await accounts.ensure(on: server, imp: imp, name: profile.name, client: client)
        guard let id = DenItemID(handle: login.handle, slug: named) else { throw ToolArgumentError("That slug can't be used.") }
        let created = try await client.put(id, summary: summary, tags: Array(tags.prefix(5)), kit: text, token: login.token)
        return "\(created ? "Shared" : "Updated") in the Den: \(client.page(of: id).absoluteString)"
    }

    private func unshare(_ args: JSONValue, _ client: DenClient, _ accounts: DenAccounts, _ server: ImpServer) async throws -> String {
        guard let login = try accounts.login(on: server, imp: imp) else { throw ToolArgumentError("You haven't shared anything.") }
        guard let id = DenItemID(handle: login.handle, slug: DenName.slug(args["slug"]?.string ?? "")) else { throw ToolArgumentError("Give the `slug` of what you shared.") }
        try await client.delete(id, token: login.token)
        return "Removed \(id) from the Den."
    }

    private func account(_ client: DenClient, _ accounts: DenAccounts, _ server: ImpServer) async throws -> String {
        guard let login = try accounts.login(on: server, imp: imp) else { return "No Den account yet: it's made the first time you share something." }
        let account = try await client.account(login.handle)
        return "Handle: \(account.handle)\n" + (account.items.isEmpty ? "Nothing shared." : account.items.map(\.line).joined(separator: "\n"))
    }

    private func itemID(_ args: JSONValue) throws -> DenItemID {
        guard let id = args["item"]?.string.flatMap(DenItemID.init) else { throw ToolArgumentError("Give the item as handle/slug.") }
        return id
    }
}
