import SwiftUI
import Testing
@testable import ImpDesign

/// The colour rules that keep text and icons readable in light and dark: the white or black the person chose
/// on a coloured control and the fill that carries it, an Imp's colour as text, and the pairs of tokens text
/// sits on. A token that fails is changed in design/tokens.json, never the threshold here.
@MainActor
@Suite("Contrast")
struct ContrastTests {
    static let schemes: [ColorScheme] = [.light, .dark]

    static func environment(_ scheme: ColorScheme) -> EnvironmentValues {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        return env
    }

    static func resolved(_ color: Color, _ scheme: ColorScheme) -> ContrastColor {
        ContrastColor(color, in: environment(scheme))
    }

    /// Every colour an Imp can have (the palette's skin: saturation .733, brightness .90 at any hue, and
    /// the same hues at other saturations and brightnesses), plus the extremes and the accent.
    static var fills: [(name: String, color: Color)] {
        var all: [(String, Color)] = [("black", .black), ("white", .white), ("ink", Tone.ink), ("paper", Tone.paper),
                                      ("accent", Tone.accent), ("mid grey", Color(white: 0.5)), ("grey .4", Color(white: 0.4)),
                                      ("grey .6", Color(white: 0.6)), ("near black", Color(white: 0.05)), ("near white", Color(white: 0.95))]
        for step in 0..<72 {
            let hue = Double(step) / 72
            for (s, b) in [(0.733, 0.90), (0.9, 0.3), (0.3, 1.0), (1.0, 1.0), (1.0, 0.5), (0.5, 0.15), (0.1, 0.85)] {
                all.append(("hue \(step) s\(s) b\(b)", Color(hue: hue, saturation: s, brightness: b)))
            }
        }
        return all
    }

    static func environment(_ scheme: ColorScheme, ink: TintInk) -> EnvironmentValues {
        var env = environment(scheme)
        env.tintInk = ink
        return env
    }

    /// The fills that have a hue, which is every colour an Imp can have.
    static var hued: [(name: String, color: Color)] { fills.filter { !resolved($0.color, .light).isNeutral } }

    @Test("White is the default on coloured controls")
    func whiteIsTheDefault() {
        #expect(EnvironmentValues().tintInk == .white)
    }

    @Test("On every Imp colour the chosen white or black is what is drawn, in both schemes")
    func theChoiceIsHonouredOnEveryHue() {
        #expect(Self.hued.count > 400)
        for scheme in Self.schemes {
            for ink in TintInk.allCases {
                let env = Self.environment(scheme, ink: ink)
                let wanted = Self.resolved(ink == .white ? Tone.paper : Tone.ink, scheme)
                for fill in Self.hued {
                    let drawn = Self.resolved(OnTint(fill.color).resolve(in: env), scheme)
                    #expect(drawn == wanted, "\(fill.name), \(ink) in \(scheme)")
                }
            }
        }
    }

    @Test("The chosen white or black has at least 4.5 to 1 on the fill it is drawn on, for any colour")
    func theChoiceReadsOnItsFill() {
        for scheme in Self.schemes {
            for ink in TintInk.allCases {
                let env = Self.environment(scheme, ink: ink)
                for fill in Self.fills {
                    let ground = Self.resolved(TintFill(fill.color).resolve(in: env), scheme)
                    let drawn = Self.resolved(OnTint(fill.color).resolve(in: env), scheme)
                    let got = Contrast.ratio(drawn, ground)
                    #expect(got >= 4.5, "\(fill.name), \(ink) in \(scheme): \(got)")
                }
            }
        }
    }

    @Test("A fill the choice already reads on is not changed, and one it does not read on keeps its hue")
    func theFillMovesOnlyAsFarAsItMust() {
        let paper = Self.resolved(Tone.paper, .light), ink = Self.resolved(Tone.ink, .light)
        let navy = ContrastColor(red: 0.1, green: 0.15, blue: 0.5)
        #expect(Contrast.control(navy, chosen: paper, ink: ink, paper: paper).fill == navy)
        let yellow = ContrastColor(red: 0.9, green: 0.8, blue: 0.24)
        let underWhite = Contrast.control(yellow, chosen: paper, ink: ink, paper: paper)
        #expect(underWhite.foreground == paper)
        #expect(underWhite.fill.luminance < yellow.luminance)
        #expect(underWhite.fill.red > underWhite.fill.blue && underWhite.fill.green > underWhite.fill.blue)
        #expect(abs(Contrast.ratio(paper, underWhite.fill) - 4.5) < 0.05)
        #expect(Contrast.control(yellow, chosen: ink, ink: ink, paper: paper).fill == yellow)
        let underBlack = Contrast.control(navy, chosen: ink, ink: ink, paper: paper)
        #expect(underBlack.foreground == ink && underBlack.fill.luminance > navy.luminance)
        #expect(underBlack.fill.blue > underBlack.fill.red)
    }

    @Test("White appeared only on dark blues and purples under the old rule, which is why it is now a choice")
    func whyWhiteWasRare() {
        // The old rule drew whichever of ink and paper had the higher ratio. On an Imp's skin
        // (saturation .733, brightness .90) paper wins only where the hue is dark by itself.
        let ink = Self.resolved(Tone.ink, .light), paper = Self.resolved(Tone.paper, .light)
        let paperHues = (0..<360).filter { degree in
            let skin = Self.resolved(Color(hue: Double(degree) / 360, saturation: 0.733, brightness: 0.90), .light)
            return !Contrast.prefersInk(on: skin, ink: ink, paper: paper)
        }
        #expect(!paperHues.isEmpty && paperHues.count < 90)
        #expect(paperHues.allSatisfy { (215...285).contains($0) }, "\(paperHues.first ?? 0)...\(paperHues.last ?? 0)")
    }

    @Test("The monochrome accent has no hue: it is not changed and carries ink or paper, whatever the choice")
    func accentOnAccent() {
        for scheme in Self.schemes {
            for ink in TintInk.allCases {
                let env = Self.environment(scheme, ink: ink)
                let accent = Self.resolved(Tone.accent, scheme)
                #expect(Self.resolved(TintFill(Tone.accent).resolve(in: env), scheme) == accent, "\(scheme)")
                let text = Self.resolved(OnTint(Tone.accent).resolve(in: env), scheme)
                #expect(Contrast.ratio(text, accent) >= 7, "\(scheme)")
            }
        }
    }

    @Test("An Imp's colour as text has at least 4.5 to 1 on the surface and on raised, in both schemes")
    func legibleTintReads() {
        for scheme in Self.schemes {
            let env = Self.environment(scheme)
            for ground in [(LegibleGround.surface, Tone.surface), (.raised, Tone.raised)] {
                let g = Self.resolved(ground.1, scheme)
                for fill in Self.fills {
                    let shown = Self.resolved(LegibleTint(fill.color, on: ground.0).resolve(in: env), scheme)
                    let got = Contrast.ratio(shown, g)
                    #expect(got >= 4.5, "\(fill.name) on \(ground.0) in \(scheme): \(got)")
                }
            }
        }
    }

    @Test("A colour that already reads is left alone")
    func legibleKeepsAGoodColour() {
        let ground = ContrastColor.black
        let green = ContrastColor(red: 0.3, green: 0.9, blue: 0.4)
        #expect(Contrast.legible(green, on: ground, lighten: true) == green)
    }

    @Test("A dark colour is lightened in dark and a light colour darkened in light, keeping its hue order")
    func legibleMovesTheRightWay() {
        let navy = ContrastColor(red: 0.05, green: 0.05, blue: 0.3)
        let lit = Contrast.legible(navy, on: Self.resolved(Tone.surface, .dark), lighten: true)
        #expect(lit.luminance > navy.luminance)
        #expect(lit.blue > lit.red)
        let butter = ContrastColor(red: 1, green: 0.95, blue: 0.6)
        let dark = Contrast.legible(butter, on: Self.resolved(Tone.surface, .light), lighten: false)
        #expect(dark.luminance < butter.luminance)
        #expect(dark.red > dark.blue)
    }

    @Test("The maths matches the known values")
    func maths() {
        #expect(abs(Contrast.ratio(.black, .white) - 21) < 0.001)
        #expect(abs(Contrast.ratio(.white, .white) - 1) < 0.001)
    }

    // MARK: Token pairs

    /// Text, its ground and the least ratio. Quiet icons (`faint`) need 3.
    private static let pairs: [(String, Color, [(String, Color)], Double)] = [
        ("text", Tone.text, [("surface", Tone.surface), ("raised", Tone.raised), ("raisedHigh", Tone.raisedHigh)], 4.5),
        ("muted", Tone.muted, [("surface", Tone.surface), ("raised", Tone.raised)], 4.5),
        ("faint", Tone.faint, [("surface", Tone.surface), ("raised", Tone.raised)], 3),
        ("link", Tone.link, [("surface", Tone.surface), ("raised", Tone.raised)], 4.5),
        ("good", Tone.good, [("surface", Tone.surface), ("raised", Tone.raised)], 4.5),
        ("danger", Tone.danger, [("surface", Tone.surface), ("raised", Tone.raised)], 4.5),
    ]

    @Test("Text tokens read on their grounds, in both schemes")
    func tokenPairs() {
        for scheme in Self.schemes {
            for (name, fg, grounds, least) in Self.pairs {
                for (groundName, ground) in grounds {
                    let g = Self.resolved(ground, scheme)
                    let got = Contrast.ratio(Self.resolved(fg, scheme), on: g)
                    #expect(got >= least, "\(name) on \(groundName) in \(scheme): \(got)")
                }
            }
        }
    }

    @Test("Text and quiet text read on a pebble, a hovered pebble and a well")
    func pebbles() {
        for scheme in Self.schemes {
            let surface = Self.resolved(Tone.surface, scheme)
            for (groundName, fill) in [("card", Tone.card), ("cardHover", Tone.cardHover), ("well", Tone.well)] {
                let ground = Self.resolved(fill, scheme).over(surface)
                for (name, fg, least) in [("text", Tone.text, 4.5), ("muted", Tone.muted, 4.5), ("faint", Tone.faint, 3)] {
                    let got = Contrast.ratio(Self.resolved(fg, scheme), on: ground)
                    #expect(got >= least, "\(name) on \(groundName) in \(scheme): \(got)")
                }
            }
        }
    }

    @Test("Notices and errors read on their backgrounds laid on the surface")
    func statusPairs() {
        for scheme in Self.schemes {
            let surface = Self.resolved(Tone.surface, scheme)
            let raised = Self.resolved(Tone.raised, scheme)
            for base in [surface, raised] {
                let warn = Self.resolved(Tone.warnBackground, scheme).over(base)
                let error = Self.resolved(Tone.errorBackground, scheme).over(base)
                let ok = Self.resolved(Tone.okBackground, scheme).over(base)
                #expect(Contrast.ratio(Self.resolved(Tone.warnText, scheme), on: warn) >= 4.5, "warnText \(scheme)")
                #expect(Contrast.ratio(Self.resolved(Tone.danger, scheme), on: error) >= 4.5, "danger on error \(scheme)")
                #expect(Contrast.ratio(Self.resolved(Tone.text, scheme), on: error) >= 4.5, "text on error \(scheme)")
                #expect(Contrast.ratio(Self.resolved(Tone.good, scheme), on: ok) >= 4.5, "good on ok \(scheme)")
            }
        }
    }

    @Test("onAccent reads on the accent")
    func onAccent() {
        for scheme in Self.schemes {
            let got = Contrast.ratio(Self.resolved(Tone.onAccent, scheme), Self.resolved(Tone.accent, scheme))
            #expect(got >= 4.5, "\(scheme): \(got)")
        }
    }

    @Test("A pebble stays visible against the surface in both schemes")
    func pebbleVisible() {
        for scheme in Self.schemes {
            let surface = Self.resolved(Tone.surface, scheme)
            let card = Self.resolved(Tone.card, scheme).over(surface)
            #expect(card != surface, "\(scheme)")
        }
    }
}
