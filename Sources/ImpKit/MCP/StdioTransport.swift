import Foundation

/// Runs a server as a child process. Newline-delimited JSON on stdin/stdout.
/// Launched through the login shell, with the environment of the user's interactive shell
/// (`LoginEnvironment`), so their PATH (npx, uvx, node…) applies however Imp was opened.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let environment: [String: String]
    private let lock = NSLock()
    private var buffer = Data()
    /// The end of what the server wrote to stderr: why it stopped, when it does.
    private var errorTail = Data()
    private let exited = DispatchSemaphore(value: 0)
    private let stderrDone = DispatchSemaphore(value: 0)
    static let errorTailLimit = 4_000

    public init(command: String, arguments: [String], environment: [String: String]) {
        (incoming, continuation) = AsyncStream.makeStream(of: JSONValue.self)
        self.environment = environment
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", Self.shellLine(command: command, arguments: arguments)]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    public var lastWords: String? {
        let tail = lock.withLock { errorTail }
        let status = process.isRunning ? nil : process.terminationStatus
        return Self.summary(stderr: String(decoding: tail, as: UTF8.self), status: status)
    }

    /// The last few lines of stderr, or what an exit status means, for the error a person sees.
    static func summary(stderr: String, status: Int32?) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            let text = lines.suffix(3).joined(separator: " ")
            return text.count > 400 ? "…" + text.suffix(399) : text
        }
        switch status {
        case 127?: return String(localized: "Command not found.")
        case let s? where s != 0: return String(localized: "It exited with status \(s).")
        default: return nil
        }
    }

    /// `exec 'cmd' 'arg'…` with every word single-quoted.
    static func shellLine(command: String, arguments: [String]) -> String {
        "exec " + ([command] + arguments).map(quote).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func start() async throws {
        process.environment = await LoginEnvironment.resolved().merging(environment) { _, new in new }
        // Always drained (a full pipe would block the server); only the end is kept.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.stderrDone.signal()
            } else {
                self.lock.withLock {
                    self.errorTail.append(data)
                    if self.errorTail.count > Self.errorTailLimit { self.errorTail = Data(self.errorTail.suffix(Self.errorTailLimit)) }
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Let the server finish exiting and its last stderr arrive, so `lastWords` says why.
                DispatchQueue.global().async {
                    _ = self.exited.wait(timeout: .now() + 2)
                    _ = self.stderrDone.wait(timeout: .now() + 0.5)
                    self.continuation.finish()
                }
            } else {
                self.consume(data)
            }
        }
        process.terminationHandler = { [exited] _ in exited.signal() }
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
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
