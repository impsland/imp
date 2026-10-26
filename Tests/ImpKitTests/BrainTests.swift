import Foundation
import Testing
@testable import ImpKit

/// Serves queued canned chat-completions bodies instead of hitting the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var queue: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.lock.withLock { Self.queue.isEmpty ? "{}" : Self.queue.removeFirst() }
        // Bodies made of `data:` lines are served as a stream (server-sent events).
        let type = body.hasPrefix("data:") ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct FakeTools: ToolProvider {
    func tools() async -> [ToolSpec] { [ToolSpec(name: "echo", description: "Echo")] }
    func call(_ name: String, arguments: String) async throws -> String {
        if name == "boom" { throw MCPError.badConfig("kaput") }
        return "got \(arguments)"
    }
}

@Suite(.serialized) struct BrainTests {
    @Test func encodesMessages() throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"a":1}"#)
        let assistant = ChatMessage.assistant(nil, toolCalls: [call]).json
        #expect(assistant["content"] is NSNull)
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "c1")
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"a":1}"#)
        let tool = ChatMessage.tool(id: "c1", content: "ok").json
        #expect(tool["tool_call_id"] as? String == "c1")
        #expect(tool["role"] as? String == "tool")
        #expect(ChatMessage.user("hi").json["content"] as? String == "hi")
    }

    @Test func encodesToolSpec() throws {
        let spec = ToolSpec(name: "t", description: "d", inputSchema: ["type": "object", "required": ["x"]])
        let json = spec.json
        #expect(json["type"] as? String == "function")
        let fn = try #require(json["function"] as? [String: Any])
        #expect(fn["name"] as? String == "t")
        #expect((fn["parameters"] as? [String: Any])?["required"] as? [String] == ["x"])
    }

    @Test func jsonValueRoundTrip() throws {
        let v = try JSONValue(jsonString: #"{"a":[1,true,null,"s"],"b":{"c":2.5}}"#)
        #expect(v["a"]?.array?.count == 4)
        #expect(v["a"]?.array?[0].int == 1)
        #expect(try JSONValue(jsonString: v.jsonString) == v)
    }

    @Test func parsesToolCallReply() throws {
        let body = #"""
        {"choices":[{"message":{"content":null,"tool_calls":[
          {"id":"c1","type":"function","function":{"name":"a__b","arguments":"{\"q\":1}"}},
          {"id":"c2","type":"function","function":{"name":"x","arguments":{"k":"v"}}}]}}]}
        """#
        let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let reply = try #require(OpenAIClient.chatReply(from: json))
        #expect(reply.text.isEmpty)
        #expect(reply.toolCalls.map(\.id) == ["c1", "c2"])
        #expect(reply.toolCalls[0].arguments == #"{"q":1}"#)
        #expect(reply.toolCalls[1].arguments == #"{"k":"v"}"#)
        #expect(OpenAIClient.chatReply(from: ["choices": [["message": ["content": ""]]]]) == nil)
    }

    private func agent(_ replies: [String], maxSteps: Int = 8) throws -> Agent {
        StubProtocol.lock.withLock { StubProtocol.queue = replies }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = try OpenAIClient(baseURL: "https://example.test/v1", apiKey: "k", session: URLSession(configuration: config))
        return Agent(client: client, model: "m", tools: FakeTools(), maxSteps: maxSteps)
    }

    private func toolReply(_ name: String) -> String {
        #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]}}]}"#
    }
    private let textReply = #"{"choices":[{"message":{"content":"done"}}]}"#

    @Test func agentRunsToolThenAnswers() async throws {
        let a = try agent([toolReply("echo"), textReply])
        let (reply, transcript) = try await a.run([.user("go")])
        #expect(reply == "done")
        #expect(transcript.map(\.role) == ["user", "assistant", "tool", "assistant"])
        #expect(transcript[2].content == "got {}")
    }

    @Test func agentTurnsToolErrorsIntoText() async throws {
        let a = try agent([toolReply("boom"), textReply])
        let (_, transcript) = try await a.run([.user("go")])
        #expect(transcript[2].content == "Error: kaput")
    }

    @Test func agentReportsToolProgress() async throws {
        let a = try agent([toolReply("echo"), toolReply("boom"), textReply])
        let events = EventLog()
        _ = try await a.run([.user("go")]) { await events.add($0) }
        #expect(await events.all == [.toolStarted("echo", arguments: "{}"), .toolFinished("echo", ok: true, result: "got {}"),
                                     .toolStarted("boom", arguments: "{}"), .toolFinished("boom", ok: false, result: "Error: kaput")])
    }

    private func sse(_ chunks: [String]) -> String {
        (chunks.map { "data: \($0)" } + ["data: [DONE]"]).joined(separator: "\n\n") + "\n\n"
    }

    @Test func agentStreamsTextAsItArrives() async throws {
        let a = try agent([sse([#"{"choices":[{"delta":{"content":"Hel"}}]}"#, #"{"choices":[{"delta":{"content":"lo!"}}]}"#])])
        let events = EventLog()
        let (reply, _) = try await a.run([.user("hi")], stream: true) { await events.add($0) }
        #expect(reply == "Hello!")
        #expect(await events.all == [.text("Hel"), .text("Hello!")])
    }

    @Test func agentStreamsToolCallsInFragments() async throws {
        let call = sse([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"ec","arguments":"{\"a\""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"ho","arguments":":1}"}}]}}]}"#,
        ])
        let a = try agent([call, sse([#"{"choices":[{"delta":{"content":"done"}}]}"#])])
        let (reply, transcript) = try await a.run([.user("go")], stream: true)
        #expect(reply == "done")
        #expect(transcript[1].toolCalls?.first == ToolCall(id: "c1", name: "echo", arguments: #"{"a":1}"#))
        #expect(transcript[2].content == #"got {"a":1}"#)
    }

    @Test func streamingFallsBackToAPlainReply() async throws {
        let a = try agent([textReply])
        let events = EventLog()
        let (reply, _) = try await a.run([.user("hi")], stream: true) { await events.add($0) }
        let seen = await events.all
        #expect(reply == "done" && seen == [.text("done")])
    }

    @Test func streamErrorsSurface() {
        var s = ChatStreamAccumulator()
        #expect(throws: APIError.self) { try s.feed(line: #"data: {"error":{"code":402,"message":"broke"}}"#) }
        #expect((try? s.feed(line: ": keep-alive")) == false)
    }

    @Test func agentStopsAfterMaxSteps() async throws {
        let a = try agent([toolReply("echo"), toolReply("echo"), textReply], maxSteps: 2)
        let (reply, transcript) = try await a.run([.user("go")])
        #expect(reply == "done")
        #expect(transcript.count == 6)
    }
}

private actor EventLog {
    private(set) var all: [AgentEvent] = []
    func add(_ e: AgentEvent) { all.append(e) }
}
