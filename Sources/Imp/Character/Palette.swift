import SwiftUI

extension Color {
    /// Imp's red: the app's accent everywhere.
    static let imp = Color.imp(0)

    /// An Imp's skin colour for a hue (0 = the original red).
    static func imp(_ hue: Double) -> Color { Palette(hue: hue).skin.color }
}

/// Every colour of one Imp, derived from its hue. Saturation and brightness are taken from the
/// original red design, so any hue keeps the same soft, matte, toy-like look.
struct Palette {
    struct RGB {
        var r, g, b: Double
        func mix(_ o: RGB, _ t: Double) -> RGB {
            let k = max(0, min(1, t))
            return RGB(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k)
        }
        var color: Color { Color(red: r, green: g, blue: b) }

        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        /// From hue (wrapping), saturation and brightness.
        init(h: Double, s: Double, b v: Double) {
            let h6 = (h - floor(h)) * 6, i = floor(h6), f = h6 - i
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch Int(i) % 6 {
            case 0: (r, g, b) = (v, t, p)
            case 1: (r, g, b) = (q, v, p)
            case 2: (r, g, b) = (p, v, t)
            case 3: (r, g, b) = (p, q, v)
            case 4: (r, g, b) = (t, p, v)
            default: (r, g, b) = (v, p, q)
            }
        }
    }

    let skinTop, skin, skinBottom, flushTop, flushBottom: RGB
    let hornLight, hornDark, blush: Color

    init(hue h: Double) {
        skinTop = RGB(h: h + 0.0077, s: 0.684, b: 0.95)
        skin = RGB(h: h + 0.0025, s: 0.733, b: 0.90)
        skinBottom = RGB(h: h - 0.0026, s: 0.778, b: 0.81)
        flushTop = RGB(h: h + 0.0083, s: 0.816, b: 0.98)
        flushBottom = RGB(h: h - 0.007, s: 0.895, b: 0.76)
        hornLight = RGB(h: h + 0.0048, s: 0.673, b: 0.52).color
        hornDark = RGB(h: h - 0.009, s: 0.73, b: 0.26).color
        blush = RGB(h: h, s: 0.45, b: 1).color
    }

    var accent: Color { skin.color }
}
