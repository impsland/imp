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

    #if DEBUG
    /// For the UI tests: a moving page drawn far past the screen (`-uiTestBackground`).
    static let uiTestPage = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>body{margin:0;width:1600px;height:2600px;background:linear-gradient(120deg,#123,#539,#c53);background-size:400% 400%;
    animation:g 6s ease infinite}@keyframes g{50%{background-position:100% 50%}}
    .s{position:absolute;width:6px;height:6px;border-radius:3px;background:#fff;animation:t 2s infinite alternate}
    @keyframes t{to{opacity:.2}}</style></head><body><script>
    for(let i=0;i<120;i++){const d=document.createElement('div');d.className='s';d.style.left=Math.random()*1600+'px';
    d.style.top=Math.random()*2600+'px';document.body.appendChild(d)}</script></body></html>
    """
    #endif
}
