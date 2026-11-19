import Foundation

/// What the app's window shows behind the Imps (the home canvas on the Mac, the room on the iPhone): one
/// HTML document, drawn full-window under every Imp and never clickable. There is no setting for it: the
/// Imps change it with `imp_set_background`. The default is one plain colour that follows light and dark.
public enum RoomBackground {
    /// The largest document an Imp may set.
    public static let maxBytes = 256 * 1024

    /// One solid colour (the app's surface), in light and in dark: a plain start for an Imp to change.
    public static let defaultHTML = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <style>
    html, body { margin: 0; height: 100%; background: #F3F1EC; }
    @media (prefers-color-scheme: dark) { html, body { background: #141519; } }
    </style>
    </head>
    <body></body>
    </html>
    """

    /// What is wrong with a document an Imp wants to set, or nil when it can be shown.
    public static func problem(_ html: String) -> String? {
        let text = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "The HTML is empty. To go back to the plain background, set `reset` to true." }
        if text.utf8.count > maxBytes { return "The HTML is \(text.utf8.count / 1024) KB. The limit is \(maxBytes / 1024) KB: draw with CSS, SVG or a canvas rather than embedded pictures." }
        return nil
    }

    /// How the tools tell the Imp what the background is now.
    public static func shown(_ html: String?) -> String {
        guard let html, html != defaultHTML else { return "The plain background (one colour, light and dark):\n\n" + defaultHTML }
        return html
    }
}
