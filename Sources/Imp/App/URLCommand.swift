import Foundation
import ImpKit

/// `imp://` commands for Shortcuts, Raycast and scripts.
enum URLCommand: CustomStringConvertible {
    case run(action: String, text: String?)   // imp://run?action=Translate%20clipboard[&text=…]
    case ask(String, imp: String?)            // imp://ask?text=…[&imp=Pip]
    case talk                                 // imp://talk
    case type(String, send: Bool)             // imp://type?text=…[&send=1]
    case settings                             // imp://settings
    case addURL(String)                        // imp://add?url=https://…  (a kit, reviewed before anything is added)
    case addInline(String)                  // imp://add?kit=<base64url JSON>

    init?(_ string: String) {
        guard let url = URLComponents(string: string), url.scheme == "imp" else { return nil }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let text = q["text"].flatMap { $0.isEmpty ? nil : $0 }
        switch url.host {
        case "run": guard let name = q["action"] else { return nil }; self = .run(action: name, text: text)
        case "ask": guard let text else { return nil }; self = .ask(text, imp: q["imp"])
        case "talk": self = .talk
        case "type": self = .type(text ?? "", send: q["send"] == "1")
        case "settings": self = .settings
        case "add":
            if let address = q["url"] { self = .addURL(address) }
            else if let kit = q["kit"], let json = try? KitSource.decode(inline: kit) { self = .addInline(json) }
            else { return nil }
        default: return nil
        }
    }

    var description: String {
        switch self {
        case .run: "run"
        case .ask: "ask"
        case .talk: "talk"
        case .type: "type"
        case .settings: "settings"
        case .addURL, .addInline: "add"
        }
    }

    @MainActor func perform(on model: AppModel) {
        switch self {
        case .run(let name, let text): model.run(named: name, text: text)
        case .ask(let text, let imp): model.ask(text, imp: imp)
        case .talk: model.talk()
        case .type(let text, let send): send ? model.submitTyped(text) : model.startTyping(prefill: text)
        case .settings: HomeWindow.shared.show(model)
        case .addURL(let url): HomeWindow.shared.showKit(model, .link(url: url, imp: HomeWindow.shared.router.selection))
        case .addInline(let json): HomeWindow.shared.showKit(model, .link(inline: json, imp: HomeWindow.shared.router.selection))
        }
    }
}
