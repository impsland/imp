import Foundation
import ImpKit

/// Downloads a kit from a web address (https, or http on this Mac): a plain GET with no cookies or
/// credentials, 10 seconds at most, no bigger than a kit may be, and only to addresses a kit may
/// come from, redirects included. The text is only read as a kit afterwards (`Kit.parse`).
enum KitLoader {
    static let timeout: TimeInterval = 10

    static func fetch(_ url: URL) async throws -> String {
        try KitSource.validate(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json, text/plain;q=0.8", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: Redirects())
            guard let http = response as? HTTPURLResponse else { throw KitError.download("That address didn't answer like a web page.") }
            guard http.statusCode == 200 else { throw KitError.download("The server answered \(http.statusCode).") }
            if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("html") == true {
                throw KitError.download("That address is a web page, not a kit. Use a link to the JSON itself (a “raw” link).")
            }
            guard response.expectedContentLength <= Int64(Kit.maxBytes) else { throw KitError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Kit.maxBytes { throw KitError.tooLarge }
            }
            guard let text = String(data: data, encoding: .utf8) else { throw KitError.download("That isn't text.") }
            return text
        } catch let error as KitError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw KitError.download("That took more than \(Int(timeout)) seconds.")
        } catch let error as URLError where error.code == .cancelled {
            throw KitError.download("That address sent Imp somewhere a kit can't come from.")
        } catch {
            throw KitError.download("Couldn't load it: \(error.localizedDescription)")
        }
    }

    /// Follows a redirect only to an address a kit may come from (never from https down to http).
    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var allowed = false
            if let url = request.url { allowed = (try? KitSource.validate(url)) != nil }
            completionHandler(allowed ? request : nil)
        }
    }
}
