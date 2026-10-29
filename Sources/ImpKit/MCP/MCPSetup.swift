import Foundation

extension MCPServerConfig {
    /// Servers from whatever an MCP server's page tells you to copy:
    /// - a JSON config: `{"mcpServers": {"name": {...}}}` (also `"servers"`), a map of named servers,
    ///   or one server object (`command`/`args`/`env`, or `url`/`headers`),
    /// - a web address (`https://…`), for a remote server,
    /// - a command line (`npx -y @scope/server-memory`), for a local one.
    /// Empty when the text is none of these.
    public static func parse(setup text: String) -> [MCPServerConfig] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.first == "{" || trimmed.first == "\"" {
            // Snippets are often a bare `"name": {...}` pair or end in a stray comma.
            var json = trimmed
            while json.last == "," { json.removeLast() }
            if json.first == "\"" { json = "{" + json + "}" }
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return servers(in: object)
        }
        var line = trimmed
        if line.hasPrefix("$ ") { line.removeFirst(2) }
        if let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return [MCPServerConfig(name: suggestedName(url: line), transport: .http, url: line)]
        }
        var server = MCPServerConfig(name: "", transport: .stdio)
        server.commandLine = line
        guard !server.command.isEmpty else { return [] }
        server.name = suggestedName(commandLine: server.arguments + [server.command])
        return [server]
    }

    private static func servers(in object: [String: Any]) -> [MCPServerConfig] {
        for key in ["mcpServers", "servers", "mcp"] {
            if let map = object[key] as? [String: Any] { return servers(in: map) }
        }
        if let one = server(from: object, name: nil) { return [one] }
        return object.keys.sorted().compactMap { name in
            (object[name] as? [String: Any]).flatMap { server(from: $0, name: name) }
        }
    }

    private static func server(from object: [String: Any], name: String?) -> MCPServerConfig? {
        let strings = { (key: String) -> [String: String] in
            (object[key] as? [String: Any])?.compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue } ?? [:]
        }
        if let url = (object["url"] ?? object["serverUrl"]) as? String, !url.isEmpty {
            return MCPServerConfig(name: name ?? suggestedName(url: url), transport: .http, url: url, headers: strings("headers"))
        }
        guard let command = object["command"] as? String, !command.isEmpty else { return nil }
        var server = MCPServerConfig(name: name ?? "", transport: .stdio, environment: strings("env"))
        let args = (object["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        // Some snippets put the whole command line in `command`.
        if args.isEmpty && command.contains(" ") { server.commandLine = command } else { server.command = command; server.arguments = args }
        if server.name.isEmpty { server.name = suggestedName(commandLine: server.arguments + [server.command]) }
        return server
    }

    /// "Memory" for `npx -y @modelcontextprotocol/server-memory`, "Fetch" for `uvx mcp-server-fetch`.
    static func suggestedName(commandLine words: [String]) -> String {
        let runners: Set = ["npx", "uvx", "bunx", "pnpx", "node", "python", "python3", "uv", "docker", "deno", "run", "-y", "--yes"]
        let word = words.first { !$0.hasPrefix("-") && !runners.contains($0) && !$0.hasPrefix("/") && !$0.hasPrefix("~") } ?? words.last ?? ""
        var base = String(word.split(separator: "/").last ?? "")
        if let at = base.firstIndex(of: "@"), at != base.startIndex { base = String(base[..<at]) }   // drop a version
        for affix in ["mcp-server-", "server-", "mcp-"] where base.hasPrefix(affix) { base.removeFirst(affix.count); break }
        for affix in ["-mcp-server", "-mcp", "-server"] where base.hasSuffix(affix) { base.removeLast(affix.count); break }
        let pretty = base.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return pretty.isEmpty ? String(localized: "New tool") : pretty
    }

    /// "Example" for `https://mcp.example.com/mcp`.
    static func suggestedName(url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return String(localized: "New tool") }
        let parts = host.split(separator: ".").filter { !["mcp", "api", "www"].contains($0) }
        let core = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? Substring(host)
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}
