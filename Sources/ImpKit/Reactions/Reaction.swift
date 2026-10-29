import Foundation

/// Everything Imp can act out: expressions, mouse games, clicks and colours, the little routines
/// it plays on its own, and body language for its answers. Which trigger starts which one is the
/// user's choice (see `AnimationRule`).
public enum Reaction: String, Codable, CaseIterable, Sendable, Identifiable {
    // Expressions (body language too, and the troupe's responses to each other).
    case greet, jump, smile, love, laugh, sad, wow, sleep, thanks, bye
    // Mouse games.
    case dizzy, mean, pet
    // Clicks and colours.
    case angry, delight
    // Feelings about how you handle it: tickles, cuddles, being carried, shaken, startled…
    case giggle, cuddle, wheee, woozy, plop, flinch, curious, shy, pounce, missedYou
    // More expressions.
    case boo, shiver, blowKiss, proud, heartbeat
    // Routines it plays on its own.
    case glance, lookAround, turn, hum, showOff, wonder, idea, nap, watch
    case dance, yawn, sneeze, peekaboo, stargaze, bored, wiggle, sneak
    // Gestures (body language). None has a trigger out of the box. Give them one in Settings.
    case yes, no, maybe, dontKnow, areYouSure, notSure, exactly, nope, hmm, aha
    case tada, sorry, oops, impressed, haha, loveIt, sadNews, careful, welcome, confused
    case phew, smug
    // Only while it wears its favourite colour.
    case twirl, serenade, cheer, swoon, glow

    public var id: String { rawValue }

    /// Only plays while the Imp wears its favourite colour (see `ImpProfile.isFavorite`).
    public var unlocksWithFavoriteColor: Bool {
        switch self {
        case .twirl, .serenade, .cheer, .swoon, .glow: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .greet: String(localized: "Nod hello")
        case .jump: String(localized: "Hop")
        case .smile: String(localized: "Smile")
        case .love: String(localized: "Heart")
        case .laugh: String(localized: "Giggle")
        case .sad: String(localized: "Sulk")
        case .wow: String(localized: "Gasp")
        case .sleep: String(localized: "Doze")
        case .thanks: String(localized: "Bow")
        case .bye: String(localized: "Wave goodbye")
        case .dizzy: String(localized: "Get dizzy")
        case .mean: String(localized: "Mean look")
        case .pet: String(localized: "Purr")
        case .angry: String(localized: "Tantrum")
        case .delight: String(localized: "Fall in love")
        case .giggle: String(localized: "Ticklish")
        case .cuddle: String(localized: "Cuddle")
        case .wheee: String(localized: "Wheee!")
        case .woozy: String(localized: "Woozy")
        case .plop: String(localized: "Plop")
        case .flinch: String(localized: "Flinch")
        case .curious: String(localized: "Curious")
        case .shy: String(localized: "Shy")
        case .pounce: String(localized: "Pounce")
        case .missedYou: String(localized: "Missed you")
        case .boo: String(localized: "Boo!")
        case .shiver: String(localized: "Shiver")
        case .blowKiss: String(localized: "Blow a kiss")
        case .proud: String(localized: "Proud")
        case .heartbeat: String(localized: "Heartbeat")
        case .dance: String(localized: "Dance")
        case .yawn: String(localized: "Yawn")
        case .sneeze: String(localized: "Sneeze")
        case .peekaboo: String(localized: "Peekaboo")
        case .stargaze: String(localized: "Stargaze")
        case .bored: String(localized: "Bored")
        case .wiggle: String(localized: "Wiggle")
        case .sneak: String(localized: "Sneak")
        case .glance: String(localized: "Glance")
        case .lookAround: String(localized: "Look around")
        case .turn: String(localized: "Turn its head")
        case .hum: String(localized: "Hum a tune")
        case .showOff: String(localized: "Show off")
        case .wonder: String(localized: "Wonder")
        case .idea: String(localized: "Get an idea")
        case .nap: String(localized: "Nap")
        case .watch: String(localized: "Watch you work")
        case .yes: String(localized: "Yes")
        case .no: String(localized: "No")
        case .maybe: String(localized: "Maybe")
        case .dontKnow: String(localized: "I don't know")
        case .areYouSure: String(localized: "Are you sure?")
        case .notSure: String(localized: "I'm not sure")
        case .exactly: String(localized: "Exactly!")
        case .nope: String(localized: "No way")
        case .hmm: String(localized: "Hmm…")
        case .aha: String(localized: "Aha!")
        case .tada: String(localized: "Ta-da!")
        case .sorry: String(localized: "Sorry")
        case .oops: String(localized: "Oops")
        case .impressed: String(localized: "Impressed")
        case .haha: String(localized: "Haha")
        case .loveIt: String(localized: "Love it")
        case .sadNews: String(localized: "Bad news")
        case .careful: String(localized: "Careful!")
        case .welcome: String(localized: "You're welcome")
        case .confused: String(localized: "Confused")
        case .phew: String(localized: "Phew")
        case .smug: String(localized: "Smug")
        case .twirl: String(localized: "Twirl")
        case .serenade: String(localized: "Serenade")
        case .cheer: String(localized: "Cheer")
        case .swoon: String(localized: "Swoon")
        case .glow: String(localized: "Glow")
        }
    }

    /// What it looks like, in a few words.
    public var summary: String {
        switch self {
        case .greet: String(localized: "A friendly double nod.")
        case .jump: String(localized: "A surprised little hop.")
        case .smile: String(localized: "Happy squinty eyes.")
        case .love: String(localized: "Hearts float up.")
        case .laugh: String(localized: "Hops and wobbles with laughter.")
        case .sad: String(localized: "Looks down and sulks.")
        case .wow: String(localized: "Eyes wide, an exclamation mark.")
        case .sleep: String(localized: "Nods off for a moment.")
        case .thanks: String(localized: "A slow little bow.")
        case .bye: String(localized: "Waves its head side to side.")
        case .dizzy: String(localized: "Spiral eyes, stars circling.")
        case .mean: String(localized: "Stops following you and stares you down.")
        case .pet: String(localized: "Leans into it, all hearts.")
        case .angry: String(localized: "Flushes red, shakes and turns away in a huff.")
        case .delight: String(localized: "Gasps, hops and showers hearts.")
        case .giggle: String(localized: "Squeezes its eyes shut and wriggles with giggles.")
        case .cuddle: String(localized: "Squishes into your hold, blushing, while you keep pressing.")
        case .wheee: String(localized: "Wide-eyed and sparkly while you carry it, swinging as it goes.")
        case .woozy: String(localized: "Spiral eyes, then shakes itself off.")
        case .plop: String(localized: "Looks left and right around its new spot.")
        case .flinch: String(localized: "Ducks and shivers, horns flat, a bead of sweat.")
        case .curious: String(localized: "Leans toward the cursor, one eye wider, wondering.")
        case .shy: String(localized: "Blushes and looks away from your stare.")
        case .pounce: String(localized: "Eyes on the bobbing cursor, then hops for it.")
        case .missedYou: String(localized: "Perks up and hops with a heart when you come back.")
        case .boo: String(localized: "Ducks, then springs up to scare you, then giggles.")
        case .shiver: String(localized: "Shivers with nerves, a bead of sweat.")
        case .blowKiss: String(localized: "A shy glance, then a kiss and a heart.")
        case .proud: String(localized: "Stands tall, chin up, sparkling.")
        case .heartbeat: String(localized: "Swells and shrinks to a heartbeat, hearts rising.")
        case .dance: String(localized: "Bops side to side to its own tune.")
        case .yawn: String(localized: "Stretches tall, a big sleepy squeeze, then blinks awake.")
        case .sneeze: String(localized: "Winds up… achoo! Then a dazed blink.")
        case .peekaboo: String(localized: "Hides its eyes, then pops back up.")
        case .stargaze: String(localized: "Gazes up, dreamy and content.")
        case .bored: String(localized: "Heavy, flat eyelids and a sigh.")
        case .wiggle: String(localized: "A quick, happy shimmy.")
        case .sneak: String(localized: "Crouches low and creeps a suspicious look around.")
        case .glance: String(localized: "Looks somewhere at random.")
        case .lookAround: String(localized: "Looks left, right, then down.")
        case .turn: String(localized: "Turns its whole head both ways.")
        case .hum: String(localized: "Music notes and a happy sway.")
        case .showOff: String(localized: "Strikes a pose.")
        case .wonder: String(localized: "Looks up with a question mark.")
        case .idea: String(localized: "Thinks hard, then a light bulb.")
        case .nap: String(localized: "Dozes off, then startles awake.")
        case .watch: String(localized: "Watches what you're doing.")
        case .yes: String(localized: "Nods twice.")
        case .no: String(localized: "Shakes its head.")
        case .maybe: String(localized: "Tilts its head this way and that.")
        case .dontKnow: String(localized: "Looks up, then shrugs with a question mark.")
        case .areYouSure: String(localized: "A sideways, sceptical squint.")
        case .notSure: String(localized: "Looks away, thinking, then a puzzled tilt.")
        case .exactly: String(localized: "A happy hop and a firm nod.")
        case .nope: String(localized: "A stern shake, then turns away.")
        case .hmm: String(localized: "Looks up, deep in thought.")
        case .aha: String(localized: "Thinks, then a light bulb and a hop.")
        case .tada: String(localized: "Gasps, then hops proudly.")
        case .sorry: String(localized: "A low bow, then a sad face.")
        case .oops: String(localized: "Startles, winces, then looks away sheepishly.")
        case .impressed: String(localized: "Wide eyes, then a happy squint.")
        case .haha: String(localized: "Rocks with laughter.")
        case .loveIt: String(localized: "Hearts and a happy tilt.")
        case .sadNews: String(localized: "Looks down, sad.")
        case .careful: String(localized: "Startles and warns you.")
        case .welcome: String(localized: "A little bow and a smile.")
        case .confused: String(localized: "Tilts its head one way, then the other, puzzled.")
        case .phew: String(localized: "A nervous sweat, then a big sigh of relief.")
        case .smug: String(localized: "Chin up, eyes closed, very pleased with itself.")
        case .twirl: String(localized: "Spins its gaze all the way round, sparkling.")
        case .serenade: String(localized: "Hums a love song, hearts drifting up.")
        case .cheer: String(localized: "Three happy hops in a row.")
        case .swoon: String(localized: "Melts into a puddle of hearts and a dreamy tilt.")
        case .glow: String(localized: "Stretches tall and proud, sparkling from head to horn.")
        }
    }

    public var symbol: String {
        switch self {
        case .greet: "hand.wave.fill"
        case .jump: "arrow.up.circle.fill"
        case .smile: "face.smiling.inverse"
        case .love, .delight: "heart.fill"
        case .laugh: "face.smiling.inverse"
        case .sad: "cloud.rain.fill"
        case .wow: "exclamationmark.circle.fill"
        case .sleep, .nap: "moon.zzz.fill"
        case .thanks: "hands.clap.fill"
        case .bye: "hand.raised.fill"
        case .dizzy: "tornado"
        case .mean: "eyes"
        case .pet: "hand.draw.fill"
        case .angry: "flame.fill"
        case .giggle: "face.smiling"
        case .cuddle: "hands.and.sparkles.fill"
        case .wheee: "hand.point.up.braille.fill"
        case .woozy: "tornado.circle.fill"
        case .plop: "arrow.down.to.line"
        case .flinch, .shiver: "drop.fill"
        case .curious: "magnifyingglass"
        case .shy: "eye.slash.fill"
        case .pounce: "cat.fill"
        case .missedYou: "heart.text.square.fill"
        case .boo: "theatermasks.fill"
        case .blowKiss: "mouth.fill"
        case .proud: "crown.fill"
        case .heartbeat: "waveform.path.ecg"
        case .dance: "figure.dance"
        case .yawn: "zzz"
        case .sneeze: "wind"
        case .peekaboo: "eye.circle.fill"
        case .stargaze: "moon.stars.fill"
        case .bored: "minus.circle.fill"
        case .wiggle: "waveform"
        case .sneak: "pawprint.fill"
        case .glance, .lookAround: "eye.fill"
        case .turn: "arrow.left.and.right"
        case .hum: "music.note"
        case .showOff: "sparkles"
        case .wonder: "questionmark.circle.fill"
        case .idea: "lightbulb.fill"
        case .watch: "keyboard.fill"
        case .yes, .exactly: "checkmark.circle.fill"
        case .no, .nope: "xmark.circle.fill"
        case .maybe: "arrow.left.arrow.right.circle.fill"
        case .dontKnow, .areYouSure, .notSure, .confused: "questionmark.bubble.fill"
        case .hmm: "ellipsis.bubble.fill"
        case .aha: "lightbulb.max.fill"
        case .tada: "party.popper.fill"
        case .sorry, .sadNews: "cloud.drizzle.fill"
        case .oops: "exclamationmark.triangle.fill"
        case .impressed: "star.fill"
        case .haha: "face.smiling.inverse"
        case .loveIt: "heart.circle.fill"
        case .careful: "exclamationmark.octagon.fill"
        case .welcome: "hands.sparkles.fill"
        case .phew: "cloud.sun.fill"
        case .smug: "hand.thumbsup.fill"
        case .twirl: "arrow.triangle.2.circlepath.circle.fill"
        case .serenade: "music.quarternote.3"
        case .cheer: "party.popper"
        case .swoon: "heart.circle"
        case .glow: "sparkle"
        }
    }
}
