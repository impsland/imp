import Foundation
import Testing
@testable import ImpKit

@Suite struct ClientTests {
    @Test func rejectsBadConfig() {
        #expect(throws: APIError.badURL("")) { try OpenAIClient(baseURL: "", apiKey: "k") }
        #expect(throws: APIError.badURL("nope")) { try OpenAIClient(baseURL: "nope", apiKey: "k") }
    }

    @Test func parsesChatContentVariants() throws {
        let a = Data(#"{"choices":[{"message":{"content":" hi "}}]}"#.utf8)
        #expect(try OpenAIClient.chatReply(from: a).text == "hi")
        let b = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"yo"}]}}]}"#.utf8)
        #expect(try OpenAIClient.chatReply(from: b).text == "yo")
    }

    @Test func readErrorsBecomeAPIErrors() {
        #expect(throws: APIError.emptyResponse("text")) {
            try OpenAIClient.chatReply(from: Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8))
        }
        #expect(throws: APIError.emptyResponse("JSON")) { try OpenAIClient.chatReply(from: Data("nope".utf8)) }
        #expect(throws: APIError.http(status: 402, message: "broke")) {
            try OpenAIClient.chatReply(from: Data(#"{"error":{"code":402,"message":"broke"}}"#.utf8))
        }
    }

    @Test func parsesModelList() {
        let d = Data(#"{"data":[{"id":"b/x"},{"id":"a/y"},{"id":"b/x"},{"name":"no id"}]}"#.utf8)
        #expect(OpenAIClient.modelIDs(from: d) == ["a/y", "b/x"])
        #expect(OpenAIClient.modelIDs(from: Data("nope".utf8)).isEmpty)
    }

    @Test func errorMessages() {
        let d = Data(#"{"error":{"message":"bad","code":400,"metadata":{"raw":"voice invalid"}}}"#.utf8)
        #expect(OpenAIClient.errorMessage(from: d) == "bad: voice invalid")
        #expect(APIError.http(status: 401, message: "x").errorDescription!.contains("401"))
    }
}

/// Records the last request so tests can inspect headers.
final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var last: URLRequest?
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.last = request }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"m1"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct KeylessClientTests {
    private func authHeader(key: String) async throws -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let client = try OpenAIClient(baseURL: "http://localhost:11434/v1", apiKey: key, session: URLSession(configuration: config))
        #expect(try await client.models() == ["m1"])
        return CaptureProtocol.lock.withLock { CaptureProtocol.last?.value(forHTTPHeaderField: "Authorization") }
    }

    @Test func emptyKeyOmitsAuthorization() async throws {
        #expect(try await authHeader(key: " ") == nil)
    }

    @Test func keySendsBearer() async throws {
        #expect(try await authHeader(key: "k") == "Bearer k")
    }
}
