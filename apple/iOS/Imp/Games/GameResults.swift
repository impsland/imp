import ImpDesign
import ImpKit
import SwiftUI

/// What the results card says, for either game: the pieces are plain values so Embers and Echo
/// share one card.
struct GameResult {
    var title: String
    var score: Int
    var best: Int
    var isRecord: Bool
    var stats: [GameStat] = []
    var prizes: [GamePrize] = []
}

struct GameStat: Identifiable {
    var value: String
    var label: String
    var id: String { label }
}

struct GamePrize: Identifiable {
    var symbol: String
    var color: Color
    var title: String
    var points: Int?
    var note: String?
    var id: String { title }
}

/// The results card of a game, top to bottom: the game's name, "New best!" when it is one, the score as
/// the hero, the best under it, at most three stats in one even row, the prizes as compact badges, and
/// the actions: Again (the one primary), Done beside it, and "How to play" as a quiet line.
///
/// The card is part of the game: the stage's chrome stays hidden until Done. It is modal for
/// VoiceOver, which lands on the score and the best (read as one element) when it appears.
struct GameResultCard: View {
    var result: GameResult
    var insets: EdgeInsets
    var again: () -> Void
    var done: () -> Void
    var howTo: () -> Void
    @ScaledMetric private var statWidth = Sizing.gameStat
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        CardFit {
            VStack(spacing: Spacing.large) {
                header
                if !result.stats.isEmpty { stats }
                if !result.prizes.isEmpty { prizes }
                actions
            }
        }
        .gameCard(insets: insets)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = true }
    }

    private var header: some View {
        VStack(spacing: Spacing.snug) {
            Text(result.title)
                .font(Typeface.caption)
                .foregroundStyle(Tone.muted)
            if result.isRecord {
                Text("games.new_best")
                    .font(Typeface.label)
                    .foregroundStyle(OnTint(SparkArt.hot))
                    .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.tight)
                    .background(TintFill(SparkArt.hot), in: Capsule())
            }
            Text(verbatim: "\(result.score)")
                .font(Typeface.display)
                .monospacedDigit()
                .foregroundStyle(Tone.text)
            if !result.isRecord {
                Text(verbatim: String.localizedStringWithFormat(NSLocalizedString("games.best", comment: ""), result.best))
                    .font(Typeface.body)
                    .foregroundStyle(Tone.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($focused)
    }

    /// At most three, in equal columns. They stack when the text is too large for them.
    private var stats: some View {
        EvenGrid(minWidth: statWidth, maxColumns: 3, spacing: Spacing.medium) {
            ForEach(result.stats) { stat in
                VStack(spacing: Spacing.hairline) {
                    Text(verbatim: stat.value)
                        .font(Typeface.title)
                        .monospacedDigit()
                        .foregroundStyle(Tone.text)
                    Text(stat.label)
                        .font(Typeface.small)
                        .foregroundStyle(Tone.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var prizes: some View {
        VStack(spacing: Spacing.small) {
            ForEach(result.prizes) { prize in
                let ink = LegibleTint(prize.color, on: .raised)
                HStack(spacing: Spacing.small) {
                    Image(systemName: prize.symbol)
                        .font(.icon(.large, weight: .semibold))
                        .foregroundStyle(ink)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(prize.title)
                            .font(Typeface.label)
                            .foregroundStyle(Tone.text)
                        if let note = prize.note {
                            Text(note)
                                .font(Typeface.small)
                                .foregroundStyle(Tone.muted)
                        }
                    }
                    if let points = prize.points {
                        Text(verbatim: "+\(points)")
                            .font(Typeface.label)
                            .monospacedDigit()
                            .foregroundStyle(ink)
                    }
                }
                .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
                .background(prize.color.opacity(Opacity.tintFill), in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Spacing.snug) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.cozy) { secondary; primary }
                VStack(spacing: Spacing.small) { primary; secondary }
            }
            Button("games.how_to", action: howTo)
                .buttonStyle(.quiet)
        }
    }

    private var primary: some View {
        Button("games.again", action: again).buttonStyle(WideButtonStyle())
    }

    private var secondary: some View {
        Button("common.done", action: done).buttonStyle(WideButtonStyle(filled: false))
    }
}

/// A card's contents: as they are if there is room, scrolling if Dynamic Type makes them too tall.
struct CardFit<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    /// The card the games put their words on: raised, with the bubble radius and the card shadow,
    /// centred, as wide as the card token allows, and clear of the screen's safe area.
    func gameCard(insets: EdgeInsets) -> some View {
        padding(Spacing.wide)
            .frame(maxWidth: Sizing.gameCard)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .shadow(color: Elevation.cardColor, radius: Elevation.cardBlur, y: Elevation.cardY)
            .padding(.horizontal, Spacing.page)
            .padding(.top, insets.top + Spacing.page)
            .padding(.bottom, insets.bottom + Spacing.page)
    }
}

enum GameCard {
    /// How a card arrives: it scales in, or only fades with Reduce Motion.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity)
    }
}

/// The top of the screen during a game: the close (X) in the trailing corner, a plain glyph, the
/// scoreboard in the middle (kept clear of the X), and what the game says under them.
struct GameTopBar<Center: View, Below: View>: View {
    var insets: EdgeInsets
    var close: () -> Void
    @ViewBuilder var center: Center
    @ViewBuilder var below: Below

    var body: some View {
        VStack(spacing: Spacing.small) {
            ZStack(alignment: .topTrailing) {
                center
                    .padding(.horizontal, Sizing.hit + Spacing.small)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                GameCloseButton(action: close)
            }
            below
                .allowsHitTesting(false)
        }
        .padding(.leading, Spacing.page + insets.leading)
        .padding(.trailing, Spacing.page - Spacing.snug + insets.trailing)
        .padding(.top, insets.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The close of a game: a plain glyph (no container) with a soft halo so it reads over the scene.
struct GameCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.icon(.large, weight: .bold))
                .foregroundStyle(Tone.paper)
                .shadow(color: Tone.scrim, radius: Spacing.snug)
                .frame(width: Sizing.hit, height: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("common.close")
    }
}
