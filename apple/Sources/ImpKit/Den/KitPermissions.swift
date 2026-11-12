import Foundation

/// What a kit would be able to do once added, in plain lines for the review sheet. It is read from
/// the parsed kit (never from text the Den adds), so a package can't describe itself kindly.
public struct KitPermissions: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case computer, command, remote, trigger, tools, shell }
        public var kind: Kind
        public var text: String
        public var id: String { "\(kind)-\(text)" }
        /// Worth a second look before adding.
        public var isCaution: Bool { kind == .computer || kind == .command || kind == .shell }
    }

    public var lines: [Line]
    public var isEmpty: Bool { lines.isEmpty }
    public var hasCautions: Bool { lines.contains(where: \.isCaution) }

    public init(_ kit: Kit) {
        func clip(_ text: String, _ limit: Int = 120) -> String {
            let one = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return one.count > limit ? String(one.prefix(limit)) + "…" : one
        }
        var out: [Line] = []
        for imp in kit.imps {
            let who = clip(imp.name.isEmpty ? String(localized: "An Imp") : imp.name, 40)
            if imp.uses(.computer) {
                out.append(Line(kind: .computer, text: String(localized: "\(who) can control your Mac: it takes screenshots and clicks and types in other apps.")))
            }
            if imp.usesShell {
                out.append(Line(kind: .shell, text: String(localized: "\(who) can run commands on your Mac.")))
            }
            let ids = imp.toolsOn.flatMap { Self.toolIDs(in: $0) }
            if !ids.isEmpty {
                out.append(Line(kind: .tools, text: String(localized: "\(who) gets these tools: \(ids.joined(separator: ", "))")))
            }
        }
        for server in kit.servers {
            let name = clip(server.name, 40)
            if server.transport == .stdio {
                out.append(Line(kind: .tools, text: String(localized: "Tool \(name) adds tools named \(Self.mcpID(server.name, "*"))")))
                out.append(Line(kind: .command, text: String(localized: "Tool \(name) runs this command on your Mac: \(clip(server.commandLine))")))
            } else {
                out.append(Line(kind: .tools, text: String(localized: "Tool \(name) adds tools named \(Self.mcpID(server.name, "*"))")))
                out.append(Line(kind: .remote, text: String(localized: "Tool \(name) connects to \(clip(server.url))")))
            }
        }
        for trigger in kit.triggers + kit.imps.flatMap(\.triggers) {
            out.append(Line(kind: .trigger, text: String(localized: "Trigger \(clip(trigger.name.isEmpty ? String(localized: "Untitled") : trigger.name, 40)) starts on: \(clip(trigger.triggerSummary))")))
        }
        lines = out
    }

    /// The group's tool IDs (`own.<group>.<tool>`), from the one tool registry.
    static func toolIDs(in group: ImpToolGroup) -> [String] {
        ToolRegistry.tools(in: group).map(\.id)
    }

    /// An extra tool's ID: `mcp.<server>.<tool>`. A kit can't know a server's tool names before it runs.
    static func mcpID(_ server: String, _ tool: String) -> String {
        ToolRegistry.mcpID(server: server, tool: tool)
    }
}

extension Kit {
    public var permissions: KitPermissions { KitPermissions(self) }
}
