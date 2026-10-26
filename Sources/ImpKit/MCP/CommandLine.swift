import Foundation

extension MCPServerConfig {
    /// The stdio command as one editable line, e.g. `npx -y @modelcontextprotocol/server-memory`.
    /// Splits on whitespace, honouring single/double quotes and backslash escapes.
    public var commandLine: String {
        get { ([command] + arguments).filter { !$0.isEmpty }.map(Self.quote).joined(separator: " ") }
        set {
            let words = Self.split(newValue)
            command = words.first ?? ""
            arguments = Array(words.dropFirst())
        }
    }

    static func split(_ line: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, inWord = false
        for ch in line {
            if escaped { word.append(ch); escaped = false; inWord = true; continue }
            switch ch {
            case "\\" where quote != "'": escaped = true
            case "'", "\"":
                if quote == nil { quote = ch; inWord = true } else if quote == ch { quote = nil } else { word.append(ch) }
            case _ where ch.isWhitespace && quote == nil:
                if inWord { words.append(word); word = ""; inWord = false }
            default: word.append(ch); inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    static func quote(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0.isWhitespace || "'\"\\".contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
