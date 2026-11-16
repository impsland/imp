import Foundation
import Network

/// A tiny OpenAI-compatible server on 127.0.0.1 for tests that need a real `AppModel` to think: each chat request
/// goes to `handler`, which answers after an optional delay, as a stream (server-sent events).
final class StubModelServer: @unchecked Sendable {
    struct Request: Sendable {
        /// Every message sent, as role and text.
        let messages: [(role: String, content: String)]
        var system: String { messages.first { $0.role == "system" }?.content ?? "" }
        var last: (role: String, content: String) { messages.last ?? ("", "") }
    }
    enum Reply: Sendable {
        case text(String, delay: Double = 0)
        case calls([(name: String, arguments: String)], delay: Double = 0)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-model-server")
    private let lock = NSLock()
    private var events: [String] = []
    let handler: @Sendable (Request) -> Reply
    private(set) var port: UInt16 = 0

    /// `log` lines the handler wrote, plus one per request, in the order they happened.
    var log: [String] { lock.withLock { events } }
    func note(_ line: String) { lock.withLock { events.append(line) } }

    init(handler: @escaping @Sendable (Request) -> Reply) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = NSLock(); nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { state in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var all = buffer; if let data { all.append(data) }
            if let split = all.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: all[..<split.lowerBound], as: UTF8.self).lowercased()
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = all[split.upperBound...]
                if body.count >= length { return self.respond(c, Data(body.prefix(length))) }
            }
            if done || error != nil { c.cancel() } else { self.read(c, all) }
        }
    }

    private func respond(_ c: NWConnection, _ body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let messages = (json["messages"] as? [[String: Any]] ?? []).map { m -> (role: String, content: String) in
            (m["role"] as? String ?? "", Self.text(m["content"]))
        }
        let reply = handler(Request(messages: messages))
        let (chunks, delay): ([String], Double)
        switch reply {
        case .text(let t, let d):
            chunks = [Self.chunk(["content": t])]; delay = d
        case .calls(let calls, let d):
            let list = calls.enumerated().map { i, call in
                ["index": i, "id": "call_\(UUID().uuidString.prefix(8))", "type": "function",
                 "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
            }
            chunks = [Self.chunk(["tool_calls": list])]; delay = d
        }
        let sse = (chunks.map { "data: \($0)" } + ["data: [DONE]"]).joined(separator: "\n\n") + "\n\n"
        queue.asyncAfter(deadline: .now() + delay) {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            c.send(content: Data((head + sse).utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private static func chunk(_ delta: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta]]])
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return ""
    }
}
