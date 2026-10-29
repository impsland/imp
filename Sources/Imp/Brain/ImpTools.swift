import AppKit
import ImpKit

/// An Imp's own tools (see `OwnTools` for what the model is told): its body, its senses, setting
/// itself up, the troupe. Offered alongside the shell and its MCP servers, run on the main actor.
struct ImpTools: ToolProvider {
    let host: OwnToolHost

    func tools() async -> [ToolSpec] { await host.specs() }
    func call(_ name: String, arguments: String) async throws -> String { try await host.call(name, arguments: arguments) }
}

/// Runs an Imp's own tools for one request.
@MainActor
final class OwnToolHost {
    private weak var app: AppModel?
    private let id: UUID
    /// Off while it answers another Imp, so two Imps can't keep messaging each other forever.
    private let messaging: Bool

    init(app: AppModel, imp: UUID, messaging: Bool) {
        self.app = app; self.id = imp; self.messaging = messaging
    }

    private var profile: ImpProfile? { app?.profile(id) }
    private var groups: Set<ImpToolGroup> {
        var g = profile?.ownTools ?? []
        if !messaging { g.remove(.troupe) }
        return g
    }

    /// Animations it may play now, by the name it calls them: its own and the shared made ones,
    /// then the built-in ones that are switched on and unlocked (some need its favourite colour).
    var playable: [(name: String, ref: AnimationRef)] {
        guard let app, let p = profile else { return [] }
        let made = app.prefs.originals(for: id).filter(\.isEnabled).map { ($0.title, AnimationRef.custom($0.id)) }
        let builtIn = Reaction.allCases.filter { app.prefs.isEnabled($0) && (!$0.unlocksWithFavoriteColor || p.isFavorite(p.hue)) }
            .map { ($0.rawValue, AnimationRef.preset($0)) }
        var seen = Set<String>()
        return (made + builtIn).filter { seen.insert($0.0.lowercased()).inserted }
    }

    /// The others it can talk to: out on the desktop, not itself.
    private var others: [ImpModel] { app?.imps.filter { $0.id != id } ?? [] }

    func specs() -> [ToolSpec] {
        OwnTools.specs(groups, animations: playable.map(\.name), imps: others.map(\.profile.name),
                       browser: BrowserBridge.shared.isConnected, talk: app?.prefs.impTalk ?? .own)
    }

    func call(_ name: String, arguments: String) async throws -> String {
        guard let group = OwnTools.group(of: name), groups.contains(group) else { throw ToolArgumentError("Unknown tool \(name).") }
        let args = (try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments)) ?? [:]
        do {
            switch name {
            case OwnTools.play: return try play(args)
            case OwnTools.move: return try await move(args)
            case OwnTools.speak: return try speak(args)
            case OwnTools.status: return app?.senses.report() ?? ""
            case OwnTools.page: return try await page(args)
            case OwnTools.listTriggers: return listTriggers()
            case OwnTools.addTrigger: return try addTrigger(args)
            case OwnTools.removeTrigger: return try removeTrigger(args)
            case OwnTools.listTools: return listTools()
            case OwnTools.addTool: return try addTool(args)
            case OwnTools.removeTool: return try removeTool(args)
            case OwnTools.openSettings: return try openSettings(args)
            case OwnTools.message: return try await message(args)
            case OwnTools.makeAnimation: return try makeAnimation(args)
            case OwnTools.showAnimation: return try showAnimation(args)
            case OwnTools.removeAnimation: return try removeAnimation(args)
            case OwnTools.setTraits: return setTraits(args)
            default: throw ToolArgumentError("Unknown tool \(name).")
            }
        } catch let error as ToolArgumentError {
            return "Error: \(error.message)"
        } catch let error as BrowserBridge.Failure {
            return "Error: \(error.localizedDescription)"
        }
    }

    private var imp: ImpModel? { app?.imp(id) }

    // MARK: Body

    private func play(_ args: JSONValue) throws -> String {
        let names = args["names"]?.array?.compactMap(\.string) ?? args["name"]?.string.map { [$0] } ?? []
        guard !names.isEmpty else { throw ToolArgumentError("Name the animations in `names`.") }
        let allowed = playable
        var picked: [AnimationRef] = [], unknown: [String] = []
        func label(_ ref: AnimationRef) -> String { allowed.first { $0.ref == ref }?.name ?? ref.key }
        for n in names.prefix(4) {
            let wanted = n.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = allowed.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }?.ref
                ?? app?.prefs.ref(named: wanted, imp: id)
            if let ref, allowed.contains(where: { $0.ref == ref }) { picked.append(ref) } else { unknown.append(n) }
        }
        guard !picked.isEmpty, let imp else { throw ToolArgumentError("None of those can play now: \(unknown.joined(separator: ", ")).") }
        let taken = imp.act(picked)
        guard taken > 0 else { throw ToolArgumentError("You've lined up \(ImpModel.maxActs) animations already: that's plenty for one answer.") }
        let queued = picked.prefix(taken).map(label).joined(separator: ", ")
        var reply = "\(imp.isBusy ? "Will play once your reply shows, after any you asked for before" : "Playing, after any already playing"): \(queued)."
        if taken < picked.count { reply += " Left out (too many for one answer): \(picked.dropFirst(taken).map(label).joined(separator: ", "))." }
        if !unknown.isEmpty { reply += " Skipped (unknown, switched off or locked): \(unknown.joined(separator: ", "))." }
        return reply
    }

    // MARK: Making animations

    private func makeAnimation(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        var problems: [String] = []
        var json = args
        if case .object(var o) = json {
            // A name that's already one of its made animations (or the shared ones) changes that one.
            if o["name"] == nil, let r = o["replaces"]?.string { o["name"] = .string(Reaction(rawValue: r)?.title ?? r) }
            json = .object(o)
        }
        guard var made = MadeAnimation(kit: json, problems: &problems) else {
            throw ToolArgumentError(problems.isEmpty ? "Give it `beats`." : problems.joined(separator: " "))
        }
        let everyone = args["for"]?.string?.lowercased() == "everyone"
        let owner: UUID? = everyone ? nil : id
        let existing = made.replaces.flatMap { r in (everyone ? app.prefs.animationLibrary : app.prefs.ownAnimations(of: id)).first { $0.replaces == r } }
            ?? (everyone ? app.prefs.animationLibrary : app.prefs.ownAnimations(of: id))
                .first { $0.replaces == nil && made.replaces == nil && $0.title.caseInsensitiveCompare(made.title) == .orderedSame }
        if let existing {
            made.id = existing.id
            if args["starts"] == nil { made.triggers = existing.triggers }
            if args["symbol"] == nil { made.symbol = existing.symbol }
        } else if made.replaces == nil {
            made.name = app.prefs.uniqueAnimationName(made.name, imp: owner)
        }
        app.prefs.save(made, for: owner)
        let ref: AnimationRef = made.replaces.map { .preset($0) } ?? .custom(made.id)
        if let imp, !imp.isBusy { app.reactions.play(ref, by: imp) } else { _ = imp?.act([ref]) }
        var reply = "\(existing == nil ? "Made" : "Changed") “\(made.title)”"
            + (made.replaces.map { " (plays instead of the built-in \($0.rawValue))" } ?? "")
            + (everyone ? " for every Imp" : " for you") + ": \(made.beats.count) beats, \(String(format: "%.1f", made.duration)) s."
        if !made.triggers.isEmpty { reply += " Starts on: \(made.triggers.map(\.rawValue).sorted().joined(separator: ", "))." }
        if !problems.isEmpty { reply += " Note: \(problems.joined(separator: " "))" }
        return reply
    }

    private func showAnimation(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        guard let name = args["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            let mine = app.prefs.ownAnimations(of: id), shared = app.prefs.animationLibrary
            func list(_ items: [MadeAnimation]) -> String {
                items.isEmpty ? "none" : items.map { a in a.title + (a.replaces.map { " (replaces \($0.rawValue))" } ?? "") }.joined(separator: ", ")
            }
            return "Your own animations: \(list(mine)). Shared with every Imp: \(list(shared)). "
                + "Your character: \((profile?.traits ?? .plain).summary) \(JSONValue.object(["traits": (profile?.traits ?? .plain).kitJSONValue]).jsonString)."
        }
        guard let ref = app.prefs.ref(named: name, imp: id), let beats = Antics.beats(for: ref, prefs: app.prefs, imp: id) else {
            throw ToolArgumentError("No animation called \(name).")
        }
        var o: [String: JSONValue] = ["beats": .array(beats.map(\.kitJSONValue))]
        switch ref {
        case .preset(let r):
            o["name"] = .string(r.rawValue)
            if let made = app.prefs.replacement(for: r, imp: id) { o["changed"] = .string(made.about.isEmpty ? "yes" : made.about) }
        case .custom(let cid):
            if let a = app.prefs.customAnimation(cid, imp: id) {
                o["name"] = .string(a.title)
                if !a.about.isEmpty { o["about"] = .string(a.about) }
                if !a.triggers.isEmpty { o["starts"] = .array(a.triggers.map { .string($0.rawValue) }) }
            }
        }
        return JSONValue.object(o).jsonString
    }

    private func removeAnimation(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = app.prefs.ownAnimations(of: id) + app.prefs.animationLibrary
        guard let found = candidates.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame || $0.replaces?.rawValue == name }) else {
            throw ToolArgumentError("No made animation called \(name) (built-in ones can be switched off in Settings, not removed).")
        }
        app.prefs.removeAnimation(found.id)
        return "Removed “\(found.title)”." + (found.replaces.map { " The built-in \($0.rawValue) plays again." } ?? "")
    }

    private func setTraits(_ args: JSONValue) -> String {
        guard let app, let i = app.prefs.imps.firstIndex(where: { $0.id == id }) else { return "Error: You're not here." }
        var t = app.prefs.imps[i].traits
        if let p = args["preset"]?.string, let preset = ImpTraits.presets.first(where: { $0.id == p.lowercased() }) { t = preset.traits }
        let keys: [(String, WritableKeyPath<ImpTraits, Double>)] = [("lids", \.lids), ("slant", \.slant), ("eyes", \.eyes), ("squint", \.squint),
                                                                   ("horns", \.horns), ("blush", \.blush), ("tilt", \.tilt), ("tempo", \.tempo)]
        for (k, path) in keys { if let v = args[k].flatMap(Self.number) { t[keyPath: path] = v } }
        app.prefs.imps[i].traits = t
        return "Your character now: \(t.normalized.summary)."
    }

    private func move(_ args: JSONValue) async throws -> String {
        guard let imp else { throw ToolArgumentError("You're not out on the desktop.") }
        let style = Travel(rawValue: args["style"]?.string?.lowercased() ?? "") ?? .hop
        let screen = (NSScreen.screens.first { $0.frame.contains(imp.impCenter) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let side = imp.impFrame.width
        // Where its head should end up (or, for named places, its whole body).
        let target: CGPoint, label: String
        if let element = args["element"]?.string, !element.isEmpty {
            guard let rect = try await BrowserBridge.shared.locate(element) else {
                throw ToolArgumentError("Couldn't find “\(element)” on the page in the browser.")
            }
            // Sit right on it: the head over the middle of the element.
            let head = imp.headOnScreen
            let offset = CGPoint(x: head.center.x - imp.impFrame.minX, y: head.center.y - imp.impFrame.minY)
            target = CGPoint(x: rect.midX - offset.x, y: rect.midY - offset.y)
            label = "onto “\(element)”"
        } else if let x = args["x"].flatMap(Self.number), let y = args["y"].flatMap(Self.number) {
            let fx = min(max(x, 0), 1), fy = min(max(y, 0), 1)
            target = CGPoint(x: screen.minX + fx * screen.width - side / 2, y: screen.maxY - fy * screen.height - side / 2)
            label = "to \(Int(fx * 100)) % across, \(Int(fy * 100)) % down"
        } else {
            let place = args["to"]?.string?.lowercased() ?? "home"
            guard OwnTools.places.contains(place) else { throw ToolArgumentError("Unknown place \(place).") }
            if place == "home" {
                guard let home = imp.homeOrigin?() else { throw ToolArgumentError("No home to go to.") }
                target = home
            } else if place == "cursor" {
                let m = NSEvent.mouseLocation
                target = CGPoint(x: m.x + 14, y: m.y - side - 4)
            } else {
                let m: CGFloat = 12
                let xs = (left: screen.minX + m, mid: screen.midX - side / 2, right: screen.maxX - side - m)
                let ys = (top: screen.maxY - side - m, mid: screen.midY - side / 2, bottom: screen.minY + m)
                let x = place.contains("left") ? xs.left : place.contains("right") ? xs.right : xs.mid
                let y = place.contains("top") ? ys.top : place.contains("bottom") ? ys.bottom : ys.mid
                target = CGPoint(x: x, y: y)
            }
            label = place == "home" ? "home" : "to the \(place)"
        }
        guard let travel = imp.onTravel else { throw ToolArgumentError("You can't move right now.") }
        await travel(target, style)
        return "Moved \(label) (\(style.rawValue))."
    }

    private static func number(_ v: JSONValue) -> Double? {
        if case .number(let n) = v { return n }
        return v.string.flatMap(Double.init)
    }

    private func speak(_ args: JSONValue) throws -> String {
        guard let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolArgumentError("Give the `text` to say.")
        }
        Speaker.shared.say(text, language: args["language"]?.string)
        return "Speaking."
    }

    // MARK: Senses

    private func page(_ args: JSONValue) async throws -> String {
        guard let page = BrowserBridge.shared.page else { throw BrowserBridge.Failure.notConnected }
        var reply = "\(page.browser): “\(page.title)” \(page.url)"
        if args["read"]?.bool == true {
            let text = try await BrowserBridge.shared.pageText()
            reply += "\n\n" + (text.isEmpty ? "(No visible text.)" : text)
        }
        return reply
    }

    // MARK: Triggers

    /// Its own triggers and the ones every Imp shares.
    private var reachable: [Shortcut] { app?.prefs.shortcuts.filter { $0.performer == id || $0.performer == nil } ?? [] }

    private func find(_ args: JSONValue) throws -> Shortcut {
        guard let key = args["id"]?.string?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { throw ToolArgumentError("Give its `id`.") }
        guard let s = reachable.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) })
        else { throw ToolArgumentError("No trigger with id \(key) (see imp_list_triggers).") }
        return s
    }

    private func listTriggers() -> String {
        let all = reachable
        guard !all.isEmpty else { return "No triggers yet." }
        return all.map(\.toolDescription).joined(separator: "\n")
    }

    private func addTrigger(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        let old = args["id"]?.string == nil ? nil : try find(args)
        let s = try Shortcut(tool: args, imp: id, replacing: old)
        if let i = app.prefs.shortcuts.firstIndex(where: { $0.id == s.id }) { app.prefs.shortcuts[i] = s } else { app.prefs.shortcuts.append(s) }
        var reply = "\(old == nil ? "Added" : "Changed") \(s.toolDescription)"
        if let keys = s.keys {
            if app.failedHotkeys.contains(keys) {
                reply += "\nBut \(keys.displayString) is already taken by macOS or another app: pick other keys."
            } else if let other = app.prefs.shortcuts.first(where: { $0.id != s.id && $0.isEnabled && $0.keys == keys }) {
                reply += "\nNote: “\(other.name)” uses the same keys and comes first."
            }
        }
        if s.trigger.kind == .website || s.conditions.contains(where: { $0.kind == .website }), !BrowserBridge.shared.isConnected {
            reply += "\nIt needs the Imp browser extension, which isn't connected: tell the user to add it (Tools › Browser in its settings)."
        }
        return reply
    }

    private func removeTrigger(_ args: JSONValue) throws -> String {
        let s = try find(args)
        app?.prefs.shortcuts.removeAll { $0.id == s.id }
        return "Removed “\(s.name)”."
    }

    // MARK: Extra tools

    private func listTools() -> String {
        guard let app, let p = profile else { return "" }
        guard !app.prefs.mcpServers.isEmpty else { return "No extra tools yet." }
        return app.prefs.mcpServers.map { s in
            let using = p.servers.contains(s.id)
            let status = app.assistant.toolStatus[s.id].map { "\($0)" } ?? "not running"
            var line = "\(s.id.uuidString): “\(s.name)” (\(s.transport == .stdio ? s.commandLine : s.url)): "
                + (using ? "you use it, \(status)" : "not used by you")
            if !s.missingSecrets.isEmpty { line += ", missing: \(s.missingSecrets.joined(separator: ", "))" }
            return line
        }.joined(separator: "\n")
    }

    private func addTool(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        var server = try MCPServerConfig(tool: args)
        var p = app.prefs
        // The same server again is the one already there (with what was filled in since).
        if let same = p.existingServer(like: server) {
            server = same
        } else {
            p.mcpServers.append(server)
        }
        if let i = p.imps.firstIndex(where: { $0.id == id }), !p.imps[i].servers.contains(server.id) { p.imps[i].servers.append(server.id) }
        app.prefs = p
        var reply = "Added “\(server.name)” (id \(server.id.uuidString)). Its tools are yours from the next message on."
        if !server.missingSecrets.isEmpty {
            reply += " It still needs: \(server.missingSecrets.joined(separator: ", ")). Open its settings (imp_open_settings, page tools, tool \(server.id.uuidString)) and ask the user to fill them in."
        }
        return reply
    }

    private func removeTool(_ args: JSONValue) throws -> String {
        guard let app, let key = args["id"]?.string,
              let server = app.prefs.mcpServers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame })
        else { throw ToolArgumentError("No extra tool with that id (see imp_list_tools).") }
        if args["everywhere"]?.bool == true {
            app.prefs.removeServer(server.id)
            return "Removed “\(server.name)” for every Imp."
        }
        if let i = app.prefs.imps.firstIndex(where: { $0.id == id }) { app.prefs.imps[i].servers.removeAll { $0 == server.id } }
        return "You no longer use “\(server.name)” (it stays in the library)."
    }

    private func openSettings(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        let tab: ImpTab = switch args["page"]?.string?.lowercased() {
        case "looks": .looks
        case "brain": .brain
        case "triggers": .triggers
        default: .tools
        }
        if tab == .tools, let key = args["tool"]?.string {
            guard let server = app.prefs.mcpServers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw ToolArgumentError("No extra tool with id \(key).")
            }
            HomeWindow.shared.router.serverToEdit = server.id
        }
        HomeWindow.shared.show(app, settingsFor: id, tab: tab)
        return "Opened \(profile?.name ?? "your")'s \(tab.rawValue) settings for the user."
    }

    // MARK: Troupe

    private func message(_ args: JSONValue) async throws -> String {
        guard let to = args["to"]?.string, let text = args["text"]?.string, !text.isEmpty else {
            throw ToolArgumentError("Say who `to` and the `text`.")
        }
        guard let other = others.first(where: { $0.profile.name.caseInsensitiveCompare(to) == .orderedSame }) else {
            throw ToolArgumentError("\(to) isn't out on the desktop.")
        }
        let me = profile ?? .imp
        let place = (app?.prefs.impTalk ?? .own).place(asked: args["chat"]?.string)
        let reply = try await other.answer(text, from: ChatTurn.Sender(id: me.id, name: me.name, hue: me.hue), in: place)
        return "\(other.profile.name) says: \(reply)"
    }
}
