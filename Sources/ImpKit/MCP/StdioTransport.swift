import Foundation

/// Runs a server as a child process. Newline-delimited JSON on stdin/stdout.
/// Launched through the login shell so the user's PATH (npx, uvx, node…) applies.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    public init(command: String, arguments: [String], environment: [String: String]) {
        (incoming, continuation) = AsyncStream.makeStream(of: JSONValue.self)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", Self.shellLine(command: command, arguments: arguments)]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
    }

    /// `exec 'cmd' 'arg'…` with every word single-quoted.
    static func shellLine(command: String, arguments: [String]) -> String {
        "exec " + ([command] + arguments).map(quote).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func start() async throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.continuation.finish()
            } else {
                self.consume(data)
            }
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            // Non-JSON lines (shell profile chatter) are ignored.
            if let value = try? JSONDecoder().decode(JSONValue.self, from: line) { continuation.yield(value) }
        }
    }

    public func send(_ message: JSONValue) async throws {
        var data = try encodeLine(message)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
