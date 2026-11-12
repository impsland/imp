import Foundation
import ImpCore

/// A model server that answered, and the models it has.
public struct LocalServer: Equatable, Sendable, Identifiable {
    public var id: String { baseURL }
    public let name: String
    public let baseURL: String
    public let models: [String]

    public init(name: String, baseURL: String, models: [String]) {
        self.name = name; self.baseURL = baseURL; self.models = models
    }
}

/// Looks for model servers on a computer: Ollama, LM Studio and llama.cpp, on their usual ports. The
/// candidates and the reading of an answer are the core's (`local_brain`). Only the request is here.
public struct LocalServerFinder: Sendable {
    /// Reads `url` and gives the body, or throws. It must give up after `timeout` seconds.
    public typealias Fetch = @Sendable (_ url: URL, _ timeout: TimeInterval) async throws -> Data

    public var host: String
    public var timeout: TimeInterval
    public var fetch: Fetch

    public init(host: String = "localhost", timeout: TimeInterval, fetch: @escaping Fetch = Self.live) {
        self.host = host; self.timeout = timeout; self.fetch = fetch
    }

    /// Every server that answers with at least one model, in the order the core lists them.
    public func find() async -> [LocalServer] {
        let candidates = ImpCore.localBrainCandidates()
        let found = await withTaskGroup(of: (Int, LocalServer?).self) { group in
            for (i, candidate) in candidates.enumerated() {
                let base = "http://\(host):\(candidate.port)/v1"
                group.addTask { (i, await probe(name: candidate.name, baseURL: base)) }
            }
            var all: [(Int, LocalServer?)] = []
            for await one in group { all.append(one) }
            return all
        }
        return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }

    /// The server at one address, or nil when it does not answer with a model list.
    public func probe(name: String, baseURL: String) async -> LocalServer? {
        guard let url = URL(string: baseURL)?.appendingPathComponent("models"),
              let body = try? await fetch(url, timeout), let text = String(data: body, encoding: .utf8) else { return nil }
        let models = ImpCore.localBrainParseModels(body: text)
        return models.isEmpty ? nil : LocalServer(name: name, baseURL: baseURL, models: models)
    }

    /// The real request. It never uses a cache and never keeps a cookie.
    public static let live: Fetch = { url, timeout in
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { throw URLError(.badServerResponse) }
        return data
    }
}
