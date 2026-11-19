import AppKit
import ImpCore
import ImpDesign
import ImpKit

/// An Imp's own tools (see `OwnTools` for what the model is told): its body, its senses, setting
/// itself up, the troupe. Offered alongside the shell and its MCP servers, run on the main actor.
struct ImpTools: ToolProvider {
    let host: OwnToolHost

    func tools() async -> [ToolSpec] { await host.specs() }
    func call(_ name: String, arguments: String) async throws -> String { try await host.call(name, arguments: arguments) }
    func run(_ name: String, arguments: String) async throws -> ToolOutput { try await host.run(name, arguments: arguments) }
}

/// Runs an Imp's own tools for one request.
@MainActor
final class OwnToolHost {
    private weak var app: AppModel?
    private let id: UUID
    /// Off while it answers another Imp, so two Imps can't keep messaging each other forever.
    private let messaging: Bool
    /// How many answers deep the turn is that uses these tools (0: you or a trigger started it). Messages it
    /// sends without waiting wake the answer at one more (`troupe::may_leave` stops chains that run away).
    private let depth: Int

    init(app: AppModel, imp: UUID, messaging: Bool, depth: Int = 0) {
        self.app = app; self.id = imp; self.messaging = messaging; self.depth = depth
    }

    private var profile: ImpProfile? { app?.profile(id) }
    /// Which groups exist for this request. What the Imp has switched off is `ToolSet`'s business
    /// (`ToolSelection`), not this: here only what can't work right now is left out.
    private var groups: Set<ImpToolGroup> {
        Set(ImpToolGroup.allCases)
    }

    /// Whether the tool is offered now: while it answers another Imp, messaging and opening files are left out.
    private func offered(_ name: String) -> Bool {
        guard let group = OwnTools.group(of: name), groups.contains(group) else { return false }
        return messaging || (name != OwnTools.message && name != OwnTools.openFile)
    }

    /// Animations it may play now, by the name it calls them: its own and the shared made ones.
    var playable: [(name: String, ref: AnimationRef)] {
        guard let app else { return [] }
        let made = app.prefs.originals(for: id).filter { $0.isEnabled }.map { ($0.title, AnimationRef.custom($0.id)) }
        var seen = Set<String>()
        return made.filter { seen.insert($0.0.lowercased()).inserted }
    }

    /// The others it can talk to: out on the desktop, not itself.
    private var others: [ImpModel] { app?.imps.filter { $0.id != id } ?? [] }

    /// Everyone it can message, by the name the tool takes: the others out on the desktop, and the Imps of
    /// other devices on the screen its body is on. A name taken here or by itself becomes `Pip@iPhone`, so
    /// an Imp called like another (on the iPhone, on the command line) is still reachable (`TalkNames`).
    private var talkNames: TalkNames<ImpModel, LinkStaged> {
        let remote = app?.link.targets(of: id) ?? []
        return TalkNames(sender: profile?.name ?? "", here: others, name: { $0.profile.name },
                         away: remote, awayName: { $0.imp.name }, place: { app?.link.name(of: $0.home) ?? "" })
    }

    func specs() -> [ToolSpec] {
        let names = talkNames
        // What each Imp it can message says about itself. What a device sent is untrusted: sanitized again.
        let profiles = names.here.map { ImpAbilities.profile(name: $0.name, about: $0.imp.profile.about, abilities: app?.abilities(of: $0.imp.profile) ?? []) }
            + names.away.map { ImpAbilities.profile(name: $0.name, about: $0.imp.imp.about, abilities: $0.imp.imp.abilities) }
        return OwnTools.specs(groups, animations: playable.map(\.name), imps: messaging ? names.here.map(\.name) : [], pocket: messaging ? names.away.map(\.name) : [],
                              browser: BrowserBridge.shared.isConnected, talk: app?.prefs.impTalk ?? .own,
                              conversation: app?.prefs.talkThreading == .decides,
                              profiles: profiles, waiting: app?.prefs.talkWaiting ?? .decides)
    }

    /// Like `call`, but a tool can hand pictures back too (`imp_open_file`).
    func run(_ name: String, arguments: String) async throws -> ToolOutput {
        guard name == OwnTools.openFile else { return ToolOutput(try await call(name, arguments: arguments)) }
        guard offered(name) else { throw ToolArgumentError("Unknown tool \(name).") }
        let args = (try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments)) ?? [:]
        do {
            return try OpenFile.open(args["file"]?.string ?? "", imp: id)
        } catch let error as ToolArgumentError {
            return ToolOutput("Error: \(error.message)")
        }
    }

    func call(_ name: String, arguments: String) async throws -> String {
        guard offered(name) else { throw ToolArgumentError("Unknown tool \(name).") }
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
            case OwnTools.openFile: return try OpenFile.open(args["file"]?.string ?? "", imp: id).text
            case OwnTools.makeAnimation: return try makeAnimation(args)
            case OwnTools.showAnimation: return try showAnimation(args)
            case OwnTools.removeAnimation: return try removeAnimation(args)
            case OwnTools.setTraits: return setTraits(args)
            case OwnTools.showBackground: return RoomBackground.shown(app?.prefs.background)
            case OwnTools.setBackground: return try setBackground(args)
            case OwnTools.addKit: return try await addKit(args)
            case OwnTools.exportKit: return try exportKit(args)
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
        let json = args
        guard var made = MadeAnimation(kit: json, problems: &problems) else {
            throw ToolArgumentError(problems.isEmpty ? "Give it `beats`." : problems.joined(separator: " "))
        }
        let everyone = args["for"]?.string?.lowercased() == "everyone"
        let owner: UUID? = everyone ? nil : id
        let existing = (everyone ? app.prefs.animationLibrary : app.prefs.ownAnimations(of: id))
            .first { $0.title.caseInsensitiveCompare(made.title) == .orderedSame }
        if let existing {
            made.id = existing.id
            if args["symbol"] == nil { made.symbol = existing.symbol }
        } else {
            made.name = app.prefs.uniqueAnimationName(made.name, imp: owner)
        }
        app.prefs.save(made, for: owner)
        let ref = AnimationRef.custom(made.id)
        if let imp, !imp.isBusy { app.reactions.play(ref, by: imp) } else { _ = imp?.act([ref]) }
        var reply = "\(existing == nil ? "Made" : "Changed") “\(made.title)”"
            + (everyone ? " for every Imp" : " for you") + ": \(made.beats.count) beats, \(String(format: "%.1f", made.duration)) s."
        if !problems.isEmpty { reply += " Note: \(problems.joined(separator: " "))" }
        return reply
    }

    private func showAnimation(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        guard let name = args["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            let mine = app.prefs.ownAnimations(of: id), shared = app.prefs.animationLibrary
            func list(_ items: [MadeAnimation]) -> String {
                items.isEmpty ? "none" : items.map(\.title).joined(separator: ", ")
            }
            return "Your own animations: \(list(mine)). Shared with every Imp: \(list(shared)). "
                + "Your character: \((profile?.traits ?? .plain).summary) \(JSONValue.object(["traits": (profile?.traits ?? .plain).kitJSONValue]).jsonString)."
        }
        guard let ref = app.prefs.ref(named: name, imp: id), let beats = Antics.beats(for: ref, prefs: app.prefs, imp: id) else {
            throw ToolArgumentError("No animation called \(name).")
        }
        var o: [String: JSONValue] = ["beats": .array(beats.map(\.kitJSONValue))]
        switch ref {
        case .custom(let cid):
            if let a = app.prefs.customAnimation(cid, imp: id) {
                o["name"] = .string(a.title)
                if !a.about.isEmpty { o["about"] = .string(a.about) }
            }
        }
        return JSONValue.object(o).jsonString
    }

    private func removeAnimation(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = app.prefs.ownAnimations(of: id) + app.prefs.animationLibrary
        guard let found = candidates.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolArgumentError("No made animation called \(name).")
        }
        let users = app.prefs.shortcuts.filter { s in
            s.steps.contains { $0.animationName?.caseInsensitiveCompare(found.title) == .orderedSame }
        }
        app.prefs.removeAnimation(found.id)
        var reply = "Removed “\(found.title)”."
        if !users.isEmpty {
            reply += " These triggers played it and now play nothing: \(users.map { "“\($0.name)” (\($0.id.uuidString))" }.joined(separator: ", ")). "
                + "Change or remove them, or tell the user."
        }
        return reply
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

    /// Replaces the page behind the Imps in the home window, or puts the plain one back.
    private func setBackground(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        if args["reset"]?.bool == true {
            app.prefs.background = RoomBackground.defaultHTML
            return "The background is the plain one again."
        }
        let html = args["html"]?.string ?? ""
        if let problem = RoomBackground.problem(html) { throw ToolArgumentError(problem) }
        app.prefs.background = html
        return "The background is set: it shows behind every Imp in the home window now."
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

    /// Its own triggers and the shared ones it has no version of.
    private var reachable: [Shortcut] { app?.prefs.triggers(for: id) ?? [] }

    private func find(_ args: JSONValue) throws -> Shortcut {
        guard let key = args["id"]?.string?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { throw ToolArgumentError("Give its `id`.") }
        guard let s = reachable.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) })
        else { throw ToolArgumentError("No trigger with id \(key) (see imp_list_triggers).") }
        return s
    }

    private func listTriggers() -> String {
        let all = reachable
        guard !all.isEmpty else { return "No triggers yet." }
        return all.map(describe).joined(separator: "\n")
    }

    /// A trigger as the model reads it.
    private func describe(_ s: Shortcut) -> String { s.toolDescription() }

    private func addTrigger(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        let old = args["id"]?.string == nil ? nil : try find(args)
        // Names as imp_play_animations lists them (switched-off and locked ones too: a trigger may wait for them).
        var s = try Shortcut(tool: args, imp: id, replacing: old)
        let everyImp = args["for"]?.string?.lowercased() == "every_imp" || args["every_imp"]?.bool == true
        s.id = app.prefs.saveTrigger(s, for: everyImp ? .everyImp : .imp(id))
        s = app.prefs.shortcuts.first { $0.id == s.id } ?? s
        var reply = "\(old == nil ? "Added" : "Changed") \(describe(s))"
        for name in s.steps.compactMap(\.animationName) {
            if let ref = app.prefs.ref(named: name, imp: id), case .custom(let made) = ref {
                if everyImp, app.prefs.owner(ofAnimation: made) == .some(id) {
                    reply += "\nNote: “\(name)” is yours alone, so the other Imps play nothing: make it `for` everyone if they should."
                } else if app.prefs.customAnimation(made, imp: id)?.isEnabled == false {
                    reply += "\nNote: “\(name)” is switched off, so nothing plays until the user switches it on (Animations in settings)."
                }
            } else {
                reply += "\nNote: there is no animation called “\(name)” yet, so nothing plays until there is."
            }
        }
        if let keys = s.keys {
            if app.failedHotkeys.contains(keys) {
                reply += "\nBut \(keys.displayString) is already taken by macOS or another app: pick other keys."
            } else if let other = app.prefs.shortcuts.first(where: { $0.id != s.id && $0.isEnabled && $0.keys == keys }) {
                reply += "\nNote: “\(other.name)” uses the same keys and comes first."
            }
        }
        if s.trigger.event == .website || s.conditions.contains(where: { $0.state == .website }), !BrowserBridge.shared.isConnected {
            reply += "\nIt needs the Imp browser extension, which isn't connected: tell the user to add it (Tools › Browser in its settings)."
        }
        return reply
    }

    private func removeTrigger(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        let s = try find(args)
        if s.performer != nil {
            app.prefs.removeTrigger(s.id, for: id)
            return app.prefs.scope(of: s, for: id) == .changed ? "Removed your version of “\(s.name)”: the shared one applies to you again." : "Removed “\(s.name)”."
        }
        if args["every_imp"]?.bool == true {
            app.prefs.removeSharedTrigger(s.id)
            return "Removed “\(s.name)” for every Imp."
        }
        app.prefs.setTrigger(s.id, enabled: false, for: id)
        return "Switched “\(s.name)” off for you. The other Imps keep it."
    }

    // MARK: Extra tools

    private func listTools() -> String {
        guard let app, let p = profile else { return "" }
        guard !app.prefs.mcpServers.isEmpty else { return "No MCP tools yet." }
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
        app.changeByPerson(p)
        var reply = "Added “\(server.name)” (id \(server.id.uuidString)). Its tools are yours from the next message on."
        if !server.missingSecrets.isEmpty {
            reply += " It still needs: \(server.missingSecrets.joined(separator: ", ")). Open its settings (imp_open_settings, page tools, tool \(server.id.uuidString)) and ask the user to fill them in."
        }
        return reply
    }

    // MARK: Kits

    /// Opens the kit review for a kit the model passes along (or fetches from an address). Nothing is
    /// added until the person confirms there.
    private func addKit(_ args: JSONValue) async throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        let text: String, origin: String
        if let kit = args["kit"], kit != .null {
            text = kit.string ?? kit.jsonString
            origin = String(localized: "Offered by your Imp")
        } else if let address = args["url"]?.string, !address.isEmpty {
            let source = try KitSource.web(address)
            guard case .remote(let url) = source else { throw ToolArgumentError("Give a `url` that starts with https://.") }
            text = try await KitLoader.fetch(url)
            origin = url.host ?? url.absoluteString
        } else {
            throw ToolArgumentError("Give `kit` (the document) or `url`.")
        }
        let kit = try Kit.parse(text)
        HomeWindow.shared.showKit(app, KitFlow.offered(json: text, imp: id, origin: origin))
        return "Opened the review for the user; nothing is added until they confirm there. It holds:\n" + kit.readableSummary
    }

    /// The kit document of one thing (or several): the same export the share buttons use, without chats
    /// and without keys.
    private func exportKit(_ args: JSONValue) throws -> String {
        guard let app else { throw ToolArgumentError("You're not here.") }
        func name(_ key: String) -> String? {
            let text = args[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        var kit = Kit(name: name("name") ?? "")
        var picked = 0
        if let wanted = name("imp") {
            guard let imp = app.prefs.imps.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolArgumentError("No Imp called \(wanted).")
            }
            // Public: no chats, no memory, and nothing about which service it uses.
            var own = ImpExport.kit([imp.id], model: app, name: imp.name)
            for i in own.imps.indices { own.imps[i].brain = nil }
            kit.imps = own.imps
            kit.servers = own.servers
            if kit.name.isEmpty { kit.name = imp.name }
            picked += 1
        }
        if let wanted = name("animation") {
            guard let made = (app.prefs.ownAnimations(of: id) + app.prefs.animationLibrary)
                .first(where: { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }) else { throw ToolArgumentError("No animation called \(wanted).") }
            if !kit.animations.contains(where: { $0.id == made.id }) { kit.animations.append(made.normalized) }
            if kit.name.isEmpty { kit.name = made.title }
            picked += 1
        }
        if let wanted = name("trigger") {
            guard let trigger = app.prefs.triggers(for: id).first(where: { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolArgumentError("No trigger called \(wanted).")
            }
            let one = app.prefs.kit(sharing: trigger, named: trigger.displayName, imp: id)
            kit.triggers += one.triggers
            for made in one.animations where !kit.animations.contains(where: { $0.id == made.id }) { kit.animations.append(made) }
            if kit.name.isEmpty { kit.name = trigger.displayName }
            picked += 1
        }
        if let wanted = name("tool") {
            guard let server = app.prefs.mcpServers.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolArgumentError("No MCP tool called \(wanted) (see imp_list_tools).")
            }
            if !kit.servers.contains(where: { $0.id == server.id }) { kit.servers.append(server) }
            if kit.name.isEmpty { kit.name = server.name }
            picked += 1
        }
        guard picked > 0 else { throw ToolArgumentError("Name what to export: `imp`, `animation`, `trigger` or `tool`.") }
        let text = kit.stamped.json(pretty: false)
        guard text.utf8.count <= Kit.maxBytes else { throw ToolArgumentError("That is too big for a kit (\(Kit.maxBytes / 1024) KB at most).") }
        return text
    }

    private func removeTool(_ args: JSONValue) throws -> String {
        guard let app, let key = args["id"]?.string,
              let server = app.prefs.mcpServers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame })
        else { throw ToolArgumentError("No MCP tool with that id (see imp_list_tools).") }
        if args["everywhere"]?.bool == true {
            app.prefs.removeServer(server.id)
            return "Removed “\(server.name)” for every Imp."
        }
        if let i = app.prefs.imps.firstIndex(where: { $0.id == id }) { app.prefs.imps[i].servers.removeAll { $0 == server.id } }
        return "You no longer use “\(server.name)” (it stays in the library)."
    }

    /// The Imp does not change settings: it opens the exact place and the user fills it in.
    private func openSettings(_ args: JSONValue) throws -> String {
        guard let app else { return "" }
        var server: MCPServerConfig?
        if let key = args["tool"]?.string {
            guard let found = app.prefs.mcpServers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw ToolArgumentError("No MCP tool with id \(key).")
            }
            server = found
        }
        let named = args["imp"]?.string
        let target = SettingsTarget(setting: args["setting"]?.string, page: args["page"]?.string, imp: named)
            ?? (server == nil ? nil : SettingsTarget(setting: .toolsServers))
        guard let target else { throw ToolArgumentError("Say which `setting` or `page` to open.") }
        var owner = id
        if let named, target.page.isPerImp {
            guard let other = app.prefs.imps.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
                throw ToolArgumentError("No Imp called \(named).")
            }
            owner = other.id
        }
        if let server { HomeWindow.shared.router.serverToEdit = server.id }
        HomeWindow.shared.show(app, target: target, imp: owner)
        return target.spoken
    }

    // MARK: Troupe

    private func message(_ args: JSONValue) async throws -> String {
        guard let to = args["to"]?.string, let text = args["text"]?.string, !text.isEmpty else {
            throw ToolArgumentError("Say who `to` and the `text`.")
        }
        let me = profile ?? .imp
        let sender = ChatTurn.Sender(id: me.id, name: me.name, hue: me.hue)
        let names = talkNames
        let found = names.find(to)
        // How the message gets there and its answer back: the same for waiting and not waiting.
        let answerer: ChatTurn.Sender
        let deliver: @MainActor () async throws -> String
        if let other = found.here {
            let place = (app?.prefs.impTalk ?? .own).place(asked: args["chat"]?.string)
            let conversation = args["conversation"]?.string
            answerer = ChatTurn.Sender(id: other.id, name: other.profile.name, hue: other.profile.hue)
            deliver = { try await other.answer(text, from: sender, in: place, conversation: conversation) }
        } else {
            guard let app, let remote = found.away else {
                let everyone = names.names.joined(separator: ", ")
                throw ToolArgumentError(everyone.isEmpty ? "\(to) isn't out on the desktop." : "\(to) isn't out on the desktop. You can message: \(everyone).")
            }
            answerer = ChatTurn.Sender(id: remote.imp.id, name: remote.imp.name, hue: remote.imp.hue)
            deliver = { try await app.link.talk(from: me, to: remote, text: text) }
        }
        let setting = app?.prefs.talkWaiting ?? .decides
        guard !setting.waits(asked: args["wait"]?.bool) else { return "\(to) says: \(try await deliver())" }

        // Not waiting: the answer comes back later as a turn of its own (`ImpModel.receive`).
        guard let app else { throw ToolArgumentError("You're not here.") }
        let pending = app.pendingMessages[id] ?? 0
        if let refusal = ImpCore.troupeMayLeave(pending: UInt32(pending), depth: UInt32(depth)) { throw ToolArgumentError(refusal) }
        let task = ImpCore.troupeTaskLabel(id: UUID().uuidString)
        let sent = Self.clock.string(from: Date()), senderID = id, askedAt = depth, name = to.trimmingCharacters(in: .whitespacesAndNewlines)
        app.pendingMessages[senderID] = pending + 1
        Task { @MainActor [weak app] in
            let result = await Self.within(seconds: Double(ImpCore.troupeLimits().asyncTimeoutSecs), deliver)
            guard let app else { return }
            if let left = app.pendingMessages[senderID] { app.pendingMessages[senderID] = left > 1 ? left - 1 : nil }
            // The sender was put away or said goodbye meanwhile: nobody to tell, the answer is dropped.
            guard let sender = app.imp(senderID) else { return }
            var text: String, failed = false
            switch result {
            case .success(let said): text = said
            case .failure(let error):
                failed = true
                text = (error as? ToolArgumentError)?.message ?? error.localizedDescription
            }
            let event = ImpCore.troupeAnswerEvent(from: name, task: task, sent: sent, text: text, failed: failed)
            sender.receive(answer: event, shown: text, from: answerer, depth: askedAt + 1)
        }
        return ImpCore.troupeReceipt(to: name, task: task)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The result of `work`, or a failure once `seconds` pass (then `work` is cancelled). An Imp that is busy
    /// answering may still finish, but nobody listens.
    private static func within(seconds: Double, _ work: @escaping @MainActor () async throws -> String) async -> Result<String, Error> {
        final class Once { var done = false }
        return await withCheckedContinuation { c in
            let once = Once()
            let finish: @MainActor (Result<String, Error>) -> Void = { result in
                guard !once.done else { return }
                once.done = true
                c.resume(returning: result)
            }
            let job = Task { @MainActor in
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                job.cancel()
                finish(.failure(ToolArgumentError("No answer came in time.")))
            }
        }
    }
}
