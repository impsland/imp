import Foundation
import ImpKit
import Observation

/// The page behind the Imps in the room (`RoomBackground`): one HTML file in Application Support, shared by
/// every Imp of this iPhone. The Imps change it with `imp_set_background`. There is no setting for it.
@MainActor @Observable
final class PhoneBackground {
    static let shared = PhoneBackground()

    /// The page drawn now.
    private(set) var html: String
    @ObservationIgnored private let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "room-background.html")) {
        self.url = url
        html = (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } ?? RoomBackground.defaultHTML
    }

    /// Sets a page (nil: the plain one) and keeps it.
    func set(_ new: String?) {
        html = new ?? RoomBackground.defaultHTML
        if new == nil || new == RoomBackground.defaultHTML {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(html.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
