import Foundation
import Testing
import ImpCore
@testable import ImpKit

/// Answers like an MCP server that wants a sign-in: 401 until a bearer token is sent.
final class HubStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        } else if let b = request.httpBody { body = b }
        let text = String(decoding: body, as: UTF8.self)
        let id = text.firstMatch(of: /"id"\s*:\s*(\d+)/).map { String($0.1) } ?? "0"
        let challenge = ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#]
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var reply = ""
        switch request.url?.absoluteString ?? "" {
        case "https://mcp.example.com/mcp":
            if request.value(forHTTPHeaderField: "Authorization") == nil { (status, headers, reply) = (401, challenge, "") }
            else if text.contains("\"initialize\"") {
                reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"n","version":"1"}}}"#
            } else if text.contains("tools/list") {
                reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"search","description":"d","inputSchema":{"type":"object"}},{"name":"read","description":"d","inputSchema":{"type":"object"}}]}}"#
            } else { status = 202 }
        case "https://mcp.example.com/.well-known/oauth-protected-resource":
            reply = #"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#
        case "https://auth.example.com/.well-known/oauth-authorization-server":
            reply = #"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","code_challenge_methods_supported":["S256"]}"#
        case "https://auth.example.com/register": status = 201; reply = #"{"client_id":"cid-1"}"#
        case "https://auth.example.com/token": reply = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#
        default: status = 404
        }
        let data = Data(reply.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Length": String(data.count)]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A presenter that counts how often the sheet opened.
final class CountingPresenter: MCPSignInPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    let cancel: Bool
    init(cancel: Bool = false) { self.cancel = cancel }
    var count: Int { lock.withLock { opened } }
    func present(_ authorizeURL: URL, callbackScheme: String) async throws -> URL {
        lock.withLock { opened += 1 }
        if cancel { throw MCPSignInError.cancelled }
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "app.imp:/oauth?code=abc&state=\(state)")!
    }
}

@Suite(.serialized) struct MCPHubSignInTests {
    private let config = MCPServerConfig(name: "Notes", transport: .http, url: "https://mcp.example.com/mcp")

    private func rig(presenter: CountingPresenter, handler: Bool = true) async -> MCPHub {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [HubStub.self]
        let session = URLSession(configuration: c)
        let file = KeyFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("imp-hub-\(UUID().uuidString)/keys.json"))
        let store = MCPAuthStore(backend: FileMCPAuth(file: file))
        let hub = MCPHub(auth: store, session: session)
        if handler {
            await hub.setSignIn { server in
                try await MCPSignIn(store: store, presenter: presenter, session: session).signIn(to: server.url)
            }
        }
        return hub
    }

    private func standIn(_ hub: MCPHub) async -> String? {
        let names = await hub.tools().map(\.name)
        guard names.count == 1, names[0].hasSuffix("sign_in") else { return nil }
        return names[0]
    }

    @Test func a401AtInitializeLeavesOnlyTheStandIn() async throws {
        let presenter = CountingPresenter()
        let hub = await rig(presenter: presenter)
        await hub.update([config])
        let name = try #require(await standIn(hub))
        #expect(name.lowercased().contains("notes"), "named like the hub names tools: \(name)")
        #expect(await hub.status[config.id] == .needsSignIn)
        let spec = try #require(await hub.tools().first)
        #expect(spec.description.contains("Notes needs the user to sign in before its tools are available"))
        await hub.reconnect(config.id)   // a background reconnect
        #expect(await standIn(hub) != nil)
        #expect(presenter.count == 0, "no sheet without a person's action")
    }

    @Test func callingTheStandInSignsInAndExposesTheRealTools() async throws {
        let presenter = CountingPresenter()
        let hub = await rig(presenter: presenter)
        await hub.update([config])
        let name = try #require(await standIn(hub))
        let result = try await hub.call(name, arguments: "{}")
        #expect(presenter.count == 1)
        #expect(result.contains("search") && result.contains("read"))
        let names = await hub.tools().map(\.name)
        #expect(names.count == 2 && !names.contains { $0.hasSuffix("sign_in") })
        guard case .ready(let count, _)? = await hub.status[config.id] else { Issue.record("not ready"); return }
        #expect(count == 2)
    }

    @Test func aCancelledSignInKeepsTheStandIn() async throws {
        let presenter = CountingPresenter(cancel: true)
        let hub = await rig(presenter: presenter)
        await hub.update([config])
        let name = try #require(await standIn(hub))
        let result = try await hub.call(name, arguments: "{}")
        #expect(result.contains("cancelled"))
        #expect(presenter.count == 1)
        #expect(await standIn(hub) == name)
        #expect(await hub.status[config.id] == .needsSignIn)
    }

    @Test func addingAServerByAPersonOpensTheSheetOnce() async throws {
        let presenter = CountingPresenter()
        let hub = await rig(presenter: presenter)
        await hub.update([config], userInitiated: true)
        let names = await hub.tools().map(\.name)
        #expect(names.count == 2 && !names.contains { $0.hasSuffix("sign_in") })
        #expect(presenter.count == 1)
        guard case .ready? = await hub.status[config.id] else { Issue.record("not ready"); return }
    }

    /// A server that appears without the person turning it on (the app starting, an Imp arriving
    /// from another device) never opens the sheet, even beside one the person just added.
    @Test func onlyTheServersThePersonTurnedOnMayOpenTheSheet() async throws {
        let presenter = CountingPresenter(cancel: true)
        let hub = await rig(presenter: presenter)
        let arrived = MCPServerConfig(name: "Arrived", transport: .http, url: "https://mcp.example.com/mcp")
        await hub.update([config, arrived], signInNow: [config.id])
        _ = await hub.tools()                                   // lets the connections finish
        #expect(presenter.count == 1)
        #expect(await hub.status[arrived.id] == .needsSignIn)
        await hub.update([config, arrived], signInNow: [])
        _ = await hub.tools()
        #expect(presenter.count == 1)
    }

    @Test func aCancelledSignInOnAddingLeavesSignInNeeded() async throws {
        let presenter = CountingPresenter(cancel: true)
        let hub = await rig(presenter: presenter)
        await hub.update([config], userInitiated: true)
        #expect(await standIn(hub) != nil)
        #expect(presenter.count == 1)
        #expect(await hub.status[config.id] == .needsSignIn)
    }

    @Test func withoutAnAttendedAppTheModelIsToldToOpenImp() async throws {
        let presenter = CountingPresenter()
        let hub = await rig(presenter: presenter, handler: false)
        await hub.setSignIn { _ in throw MCPSignInError.notAttended }
        await hub.update([config])
        let name = try #require(await standIn(hub))
        let result = try await hub.call(name, arguments: "{}")
        #expect(result == "Open Imp and sign in to Notes in Tools")
        #expect(presenter.count == 0)
        #expect(await standIn(hub) == name)
    }
}
