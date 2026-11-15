import Foundation
import ImpCore

extension MCPServerConfig {
    /// The stdio command as one editable line, e.g. `npx -y @modelcontextprotocol/server-memory`.
    /// Read and written as a shell does (quotes and backslashes), by the core, as the command line app does.
    public var commandLine: String {
        get { ImpCore.mcpJoinCommandLine(command: command, args: arguments) }
        set {
            let words = Self.split(newValue)
            command = words.first ?? ""
            arguments = Array(words.dropFirst())
        }
    }

    static func split(_ line: String) -> [String] {
        ImpCore.mcpSplitCommandLine(line: line)
    }
}
