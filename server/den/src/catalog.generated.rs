// generated from spec/animations/catalog.json, do not edit. Run: node design/generate.mjs

/// The animation catalog as the repository keeps it (the apps read the same file).
pub const CATALOG: &str = r###"{
  "name": "Imp animations",
  "about": "Every animation Imp ships with or the Den offers. The five marked bundled are built into the apps. The defaults say which of them starts each gesture out of the box, so an offline Imp is never still. An animation installed for a gesture takes it over. The Den seeds the whole list when it starts. An animation marked favoriteColor plays only while an Imp wears its favourite colour.",
  "defaults": {
    "poke": "wow",
    "swish": "wow",
    "rush": "wow",
    "shake": "wow",
    "drop": "wow",
    "dangle": "wow",
    "circle": "wow",
    "stroke": "smile",
    "tickle": "smile",
    "hold": "smile",
    "pickUp": "smile",
    "favoriteColor": "smile",
    "comeback": "smile",
    "linger": "greet",
    "stare": "greet"
  },
  "animations": [
    { "id": "greet", "name": "Nod hello", "about": "A friendly double nod.", "bundled": true, "starts": [],
      "beats": [
        {"duration":0.2,"look":[0,0.5]},
        {"duration":0.2,"look":[0,0.1]},
        {"duration":0.2,"look":[0,0.45]},
        {"duration":0.3,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "jump", "name": "Hop", "about": "A surprised little hop.", "starts": [],
      "beats": [
        {"duration":0.46,"hop":true,"look":[0,-0.3],"mood":"surprised"},
        {"duration":0.44,"look":[0,0],"mood":"happy"}
      ] },
    { "id": "smile", "name": "Smile", "about": "Happy squinty eyes.", "bundled": true, "starts": ["idle"],
      "beats": [
        {"duration":0.9,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "love", "name": "Heart", "about": "Hearts float up.", "starts": ["idle"],
      "beats": [
        {"duration":0.9,"look":[0,0.1],"mood":"love"}
      ] },
    { "id": "laugh", "name": "Giggle", "about": "Hops and wobbles with laughter.", "starts": [],
      "beats": [
        {"duration":0.44,"hop":true,"look":[0.1,-0.2],"mood":"happy","tilt":-6},
        {"duration":0.46,"look":[0,0.1],"mood":"happy","tilt":6}
      ] },
    { "id": "sad", "name": "Sulk", "about": "Looks down and sulks.", "bundled": true, "starts": [],
      "beats": [
        {"duration":0.9,"look":[-0.2,0.5],"mood":"sad"}
      ] },
    { "id": "wow", "name": "Gasp", "about": "Eyes wide, an exclamation mark.", "bundled": true, "starts": [],
      "beats": [
        {"duration":0.9,"glyph":"exclaim","look":[0,0.1],"mood":"surprised"}
      ] },
    { "id": "sleep", "name": "Doze", "about": "Nods off for a moment.", "bundled": true, "starts": [],
      "beats": [
        {"duration":0.9,"look":[0,0.35],"mood":"sleepy"}
      ] },
    { "id": "thanks", "name": "Bow", "about": "A slow little bow.", "starts": [],
      "beats": [
        {"duration":0.38,"look":[0,0.75]},
        {"duration":0.52,"look":[0,0.1],"mood":"love"}
      ] },
    { "id": "bye", "name": "Wave goodbye", "about": "Waves its head side to side.", "starts": [],
      "beats": [
        {"duration":0.26,"look":[-0.4,0],"tilt":-8},
        {"duration":0.26,"look":[0.4,0],"tilt":8},
        {"duration":0.26,"look":[-0.4,0],"tilt":-8},
        {"duration":0.13,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "dizzy", "name": "Get dizzy", "about": "Spiral eyes, stars circling.", "starts": ["circle"],
      "beats": [
        {"duration":0.68,"look":[0.15,-0.1],"mood":"dizzy"},
        {"duration":0.22,"look":[0,0],"mood":"surprised"}
      ] },
    { "id": "mean", "name": "Mean look", "about": "Stops following you and stares you down.", "starts": ["swish"],
      "beats": [
        {"duration":0.68,"look":[0,0.05],"mood":"mean"},
        {"duration":0.22,"look":[0.6,0.1],"mood":"mean","tilt":4}
      ] },
    { "id": "pet", "name": "Purr", "about": "Leans into it, all hearts.", "starts": ["stroke"],
      "beats": [
        {"duration":0.9,"look":[0,-0.35],"mood":"love","tilt":5}
      ] },
    { "id": "angry", "name": "Tantrum", "about": "Flushes red, shakes and turns away in a huff.", "starts": ["poke"],
      "beats": [
        {"duration":0.31,"glyph":"exclaim","hop":true,"look":[0,0.1],"mood":"annoyed"},
        {"duration":0.38,"look":[0,0.2],"mood":"annoyed","tilt":-3},
        {"duration":0.2,"look":[0.75,-0.1],"mood":"mean","tilt":7}
      ] },
    { "id": "delight", "name": "Fall in love", "about": "Gasps, hops and showers hearts.", "starts": ["favoriteColor"],
      "beats": [
        {"duration":0.31,"glyph":"exclaim","look":[0,0.1],"mood":"surprised"},
        {"duration":0.4,"hop":true,"look":[0,0.1],"mood":"love","tilt":-5},
        {"duration":0.19,"look":[0,0.1],"mood":"happy","tilt":4}
      ] },
    { "id": "giggle", "name": "Ticklish", "about": "Squeezes its eyes shut and wriggles with giggles.", "starts": ["tickle"],
      "beats": [
        {"duration":0.33,"hop":true,"look":[-0.1,-0.1],"mood":"giggly","tilt":-6},
        {"duration":0.35,"look":[0.1,-0.1],"mood":"giggly","tilt":6},
        {"duration":0.22,"look":[0,0.1],"mood":"happy","tilt":-3}
      ] },
    { "id": "cuddle", "name": "Cuddle", "about": "Squishes into your hold, blushing, while you keep pressing.", "starts": ["hold"],
      "beats": [
        {"duration":0.32,"look":[0,0.1],"mood":"content","stretch":-0.06},
        {"duration":0.58,"glyph":"heart","look":[0,0.1],"mood":"content","stretch":-0.08,"tilt":4}
      ] },
    { "id": "wheee", "name": "Wheee!", "about": "Wide-eyed and sparkly while you carry it, swinging as it goes.", "starts": ["pickUp"],
      "beats": [
        {"duration":0.32,"glyph":"exclaim","look":[0,-0.3],"mood":"surprised"},
        {"duration":0.58,"look":[0,0.45],"mood":"excited"}
      ] },
    { "id": "woozy", "name": "Woozy", "about": "Spiral eyes, then shakes itself off.", "starts": ["shake"],
      "beats": [
        {"duration":0.32,"look":[0.1,-0.1],"mood":"dizzy"},
        {"duration":0.14,"look":[-0.5,0]},
        {"duration":0.14,"look":[0.5,0]},
        {"duration":0.14,"look":[-0.5,0]},
        {"duration":0.16,"look":[0,0.1],"mood":"bored"}
      ] },
    { "id": "plop", "name": "Plop", "about": "Looks left and right around its new spot.", "starts": ["drop"],
      "beats": [
        {"duration":0.35,"look":[-0.7,-0.05]},
        {"duration":0.35,"look":[0.7,-0.05]},
        {"duration":0.21,"look":[0,0.1]}
      ] },
    { "id": "flinch", "name": "Flinch", "about": "Ducks and shivers, horns flat, a bead of sweat.", "starts": ["rush"],
      "beats": [
        {"duration":0.25,"glyph":"exclaim","look":[0,0.1],"mood":"surprised","stretch":-0.1},
        {"duration":0.65,"glyph":"sweat","look":[0.3,0.35],"mood":"scared"}
      ] },
    { "id": "curious", "name": "Curious", "about": "Leans toward the cursor, one eye wider, wondering.", "starts": ["linger"],
      "beats": [
        {"duration":0.9,"glyph":"question","mood":"curious"}
      ] },
    { "id": "shy", "name": "Shy", "about": "Blushes and looks away from your stare.", "starts": ["stare"],
      "beats": [
        {"duration":0.3,"look":[0,0.1],"mood":"surprised"},
        {"duration":0.6,"glyph":"sweat","mood":"shy"}
      ] },
    { "id": "pounce", "name": "Pounce", "about": "Eyes on the bobbing cursor, then hops for it.", "starts": ["dangle"],
      "beats": [
        {"duration":0.26,"mood":"excited"},
        {"duration":0.26,"hop":true,"mood":"excited"},
        {"duration":0.26,"hop":true,"mood":"excited"},
        {"duration":0.13,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "missedYou", "name": "Missed you", "about": "Perks up and hops with a heart when you come back.", "starts": ["comeback"],
      "beats": [
        {"duration":0.31,"glyph":"exclaim","look":[0,0.1],"mood":"surprised"},
        {"duration":0.37,"glyph":"heart","hop":true,"look":[0,0.1],"mood":"excited"},
        {"duration":0.22,"look":[0,0.1],"mood":"love"}
      ] },
    { "id": "boo", "name": "Boo!", "about": "Ducks, then springs up to scare you, then giggles.", "starts": [],
      "beats": [
        {"duration":0.33,"look":[0,0.6],"stretch":-0.15},
        {"duration":0.35,"glyph":"exclaim","hop":true,"look":[0,0.1],"mood":"annoyed","stretch":0.08},
        {"duration":0.22,"look":[0,0.1],"mood":"giggly"}
      ] },
    { "id": "shiver", "name": "Shiver", "about": "Shivers with nerves, a bead of sweat.", "starts": [],
      "beats": [
        {"duration":0.9,"glyph":"sweat","look":[0.2,0.3],"mood":"scared"}
      ] },
    { "id": "blowKiss", "name": "Blow a kiss", "about": "A shy glance, then a kiss and a heart.", "starts": [],
      "beats": [
        {"duration":0.41,"mood":"shy"},
        {"duration":0.49,"glyph":"heart","look":[0,0.1],"mood":"love","tilt":-6}
      ] },
    { "id": "proud", "name": "Proud", "about": "Stands tall, chin up, sparkling.", "starts": [],
      "beats": [
        {"duration":0.9,"glyph":"sparkles","look":[0.1,-0.5],"mood":"happy","stretch":0.1}
      ] },
    { "id": "heartbeat", "name": "Heartbeat", "about": "Swells and shrinks to a heartbeat, hearts rising.", "starts": [],
      "beats": [
        {"duration":0.2,"glyph":"heart","look":[0,0.1],"mood":"love","stretch":0.1},
        {"duration":0.2,"glyph":"heart","look":[0,0.1],"mood":"love","stretch":-0.08},
        {"duration":0.2,"glyph":"heart","look":[0,0.1],"mood":"love","stretch":0.1},
        {"duration":0.2,"glyph":"heart","look":[0,0.1],"mood":"love","stretch":-0.08},
        {"duration":0.1,"look":[0,0.1],"mood":"content"}
      ] },
    { "id": "glance", "name": "Glance", "about": "Looks somewhere at random.", "starts": ["idle"],
      "beats": [
        {"duration":0.9,"look":[0.88,0.47],"tilt":-4.86}
      ] },
    { "id": "lookAround", "name": "Look around", "about": "Looks left, right, then down.", "starts": ["idle"],
      "beats": [
        {"duration":0.35,"look":[-0.85,-0.2]},
        {"duration":0.35,"look":[0.85,-0.3]},
        {"duration":0.19,"look":[0,0.25]}
      ] },
    { "id": "turn", "name": "Turn its head", "about": "Turns its whole head both ways.", "starts": ["idle"],
      "beats": [
        {"duration":0.35,"look":[-0.95,0],"tilt":-6},
        {"duration":0.35,"look":[0.95,0],"tilt":6},
        {"duration":0.21,"look":[0,0]}
      ] },
    { "id": "hum", "name": "Hum a tune", "about": "Music notes and a happy sway.", "starts": ["idle"],
      "beats": [
        {"duration":0.69,"glyph":"notes","look":[0.25,-0.45],"mood":"happy","tilt":5},
        {"duration":0.21,"look":[0.1,-0.1],"tilt":2}
      ] },
    { "id": "showOff", "name": "Show off", "about": "Strikes a pose.", "starts": ["idle"],
      "beats": [
        {"duration":0.42,"glyph":"exclaim","look":[0,0],"mood":"surprised"},
        {"duration":0.48,"look":[0.9,0.35],"mood":"happy","tilt":8}
      ] },
    { "id": "wonder", "name": "Wonder", "about": "Looks up with a question mark.", "starts": ["idle"],
      "beats": [
        {"duration":0.9,"glyph":"question","look":[-0.5,-0.7],"mood":"thinking","tilt":-6}
      ] },
    { "id": "idea", "name": "Get an idea", "about": "Thinks hard, then a light bulb.", "starts": ["idle"],
      "beats": [
        {"duration":0.52,"look":[0.3,-0.8],"mood":"thinking"},
        {"duration":0.38,"glyph":"idea","look":[0,0],"mood":"happy"}
      ] },
    { "id": "nap", "name": "Nap", "about": "Dozes off, then startles awake.", "starts": ["idle"],
      "beats": [
        {"duration":0.66,"look":[0,0.35],"mood":"sleepy"},
        {"duration":0.24,"glyph":"exclaim","look":[0,0],"mood":"surprised"}
      ] },
    { "id": "watch", "name": "Watch you work", "about": "Watches what you're doing.", "starts": ["idle"],
      "beats": [
        {"duration":0.9,"look":[0,0],"tilt":4}
      ] },
    { "id": "dance", "name": "Dance", "about": "Bops side to side to its own tune.", "starts": ["idle"],
      "beats": [
        {"duration":0.2,"glyph":"notes","hop":true,"look":[-0.3,-0.1],"mood":"happy","tilt":-10},
        {"duration":0.2,"glyph":"notes","look":[0.3,-0.1],"mood":"happy","tilt":10},
        {"duration":0.2,"glyph":"notes","hop":true,"look":[-0.3,-0.1],"mood":"happy","tilt":-10},
        {"duration":0.2,"glyph":"notes","look":[0.3,-0.1],"mood":"happy","tilt":10},
        {"duration":0.1,"look":[0,0.1],"mood":"content"}
      ] },
    { "id": "yawn", "name": "Yawn", "about": "Stretches tall, a big sleepy squeeze, then blinks awake.", "starts": ["idle"],
      "beats": [
        {"duration":0.38,"look":[0,-0.35],"mood":"sleepy","stretch":0.12},
        {"duration":0.32,"look":[0,0.1],"stretch":-0.05},
        {"duration":0.2,"look":[0,0.1]}
      ] },
    { "id": "sneeze", "name": "Sneeze", "about": "Winds up… achoo! Then a dazed blink.", "starts": ["idle"],
      "beats": [
        {"duration":0.35,"look":[0,-0.4],"mood":"surprised","stretch":0.06},
        {"duration":0.31,"hop":true,"look":[0,0.5],"mood":"error","stretch":-0.1},
        {"duration":0.23,"look":[0,0.1],"mood":"bored"}
      ] },
    { "id": "peekaboo", "name": "Peekaboo", "about": "Hides its eyes, then pops back up.", "starts": ["idle"],
      "beats": [
        {"duration":0.36,"look":[0,1],"stretch":-0.12},
        {"duration":0.34,"glyph":"exclaim","hop":true,"look":[0,0.1],"mood":"surprised","stretch":0.06},
        {"duration":0.2,"look":[0,0.1],"mood":"giggly"}
      ] },
    { "id": "stargaze", "name": "Stargaze", "about": "Gazes up, dreamy and content.", "starts": ["idle"],
      "beats": [
        {"duration":0.64,"glyph":"sparkles","look":[-0.2,-0.85],"tilt":-4},
        {"duration":0.26,"look":[0,-0.3],"mood":"content"}
      ] },
    { "id": "bored", "name": "Bored", "about": "Heavy, flat eyelids and a sigh.", "starts": ["idle"],
      "beats": [
        {"duration":0.4,"mood":"bored"},
        {"duration":0.32,"look":[0.3,0.2],"mood":"bored","stretch":-0.06},
        {"duration":0.17,"look":[0,0.1]}
      ] },
    { "id": "wiggle", "name": "Wiggle", "about": "A quick, happy shimmy.", "starts": ["idle"],
      "beats": [
        {"duration":0.14,"hop":true,"look":[-0.2,-0.1],"mood":"excited","tilt":-12},
        {"duration":0.14,"look":[0.2,-0.1],"mood":"excited","tilt":12},
        {"duration":0.14,"look":[-0.2,-0.1],"mood":"excited","tilt":-12},
        {"duration":0.14,"look":[0.2,-0.1],"mood":"excited","tilt":12},
        {"duration":0.14,"look":[-0.2,-0.1],"mood":"excited","tilt":-12},
        {"duration":0.2,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "sneak", "name": "Sneak", "about": "Crouches low and creeps a suspicious look around.", "starts": ["idle"],
      "beats": [
        {"duration":0.32,"look":[-0.8,0.1],"mood":"mean","stretch":-0.12},
        {"duration":0.35,"look":[0.8,0.1],"mood":"mean","stretch":-0.12,"tilt":5},
        {"duration":0.23,"look":[0,0.1],"mood":"giggly","stretch":-0.04}
      ] },
    { "id": "pirouette", "name": "Pirouette", "about": "Spins all the way round on the spot, like a dancer.", "starts": ["idle"],
      "beats": [
        {"duration":0.26,"look":[0,-0.2],"mood":"content","stretch":0.08},
        {"duration":0.26,"glyph":"sparkles","look":[0,-0.1],"mood":"happy","move":"spin","stretch":0.1},
        {"duration":0.26,"look":[0,0.6]},
        {"duration":0.13,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "backflip", "name": "Backflip", "about": "Crouches, springs up and somersaults backwards.", "starts": ["idle"],
      "beats": [
        {"duration":0.26,"look":[0,0.3],"mood":"excited","stretch":-0.14},
        {"duration":0.26,"look":[0,-0.2],"mood":"excited","move":"flip","reverse":true,"stretch":0.06},
        {"duration":0.26,"glyph":"exclaim","look":[0,0.1],"mood":"surprised","stretch":-0.1},
        {"duration":0.13,"glyph":"sparkles","look":[0,0.1],"mood":"happy","stretch":0.04,"tilt":5}
      ] },
    { "id": "cartwheel", "name": "Cartwheel", "about": "Turns a whole cartwheel and lands with a grin.", "starts": ["idle"],
      "beats": [
        {"duration":0.31,"look":[0.5,0],"mood":"excited","stretch":-0.06,"tilt":-6},
        {"duration":0.38,"look":[0.3,-0.1],"mood":"excited","move":"roll"},
        {"duration":0.22,"look":[0,0.1],"mood":"giggly","tilt":4}
      ] },
    { "id": "boing", "name": "Boing", "about": "Bounces up and down like a rubber ball.", "starts": ["idle"],
      "beats": [
        {"duration":0.4,"look":[0,-0.15],"mood":"giggly","move":"bounce","times":4},
        {"duration":0.32,"look":[0.1,0],"mood":"dizzy","move":"wobble","times":2},
        {"duration":0.18,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "levitate", "name": "Levitate", "about": "Closes its eyes and floats up off the desk.", "starts": ["idle"],
      "beats": [
        {"duration":0.31,"look":[0,0.1],"mood":"content"},
        {"duration":0.42,"glyph":"sparkles","look":[0,-0.25],"mood":"content","move":"float"},
        {"duration":0.17,"look":[0,0.1],"mood":"surprised"}
      ] },
    { "id": "yes", "name": "Yes", "about": "Nods twice.", "starts": [],
      "beats": [
        {"duration":0.18,"look":[0,0.45]},
        {"duration":0.18,"look":[0,0.1]},
        {"duration":0.18,"look":[0,0.45]},
        {"duration":0.36,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "no", "name": "No", "about": "Shakes its head.", "starts": [],
      "beats": [
        {"duration":0.18,"look":[-0.5,0.1]},
        {"duration":0.18,"look":[0.5,0.1]},
        {"duration":0.18,"look":[-0.5,0.1]},
        {"duration":0.18,"look":[0.5,0.1]},
        {"duration":0.18,"look":[0,0.1]}
      ] },
    { "id": "maybe", "name": "Maybe", "about": "Tilts its head this way and that.", "starts": [],
      "beats": [
        {"duration":0.34,"look":[-0.3,-0.1],"tilt":-10},
        {"duration":0.34,"look":[0.3,-0.1],"tilt":10},
        {"duration":0.22,"look":[0,0.1]}
      ] },
    { "id": "dontKnow", "name": "I don't know", "about": "Looks up, then shrugs with a question mark.", "starts": [],
      "beats": [
        {"duration":0.41,"look":[-0.4,-0.6],"mood":"thinking","tilt":-6},
        {"duration":0.49,"glyph":"question","hop":true,"look":[0,0.1],"mood":"surprised","tilt":7}
      ] },
    { "id": "areYouSure", "name": "Are you sure?", "about": "A sideways, sceptical squint.", "starts": [],
      "beats": [
        {"duration":0.9,"glyph":"question","look":[0.1,0.15],"mood":"mean","tilt":9}
      ] },
    { "id": "notSure", "name": "I'm not sure", "about": "Looks away, thinking, then a puzzled tilt.", "starts": [],
      "beats": [
        {"duration":0.47,"look":[-0.6,0.2],"mood":"thinking","tilt":-4},
        {"duration":0.43,"glyph":"question","look":[0.3,-0.2],"mood":"curious"}
      ] },
    { "id": "exactly", "name": "Exactly!", "about": "A happy hop and a firm nod.", "starts": [],
      "beats": [
        {"duration":0.39,"hop":true,"look":[0,0.1],"mood":"happy"},
        {"duration":0.2,"look":[0,0.5]},
        {"duration":0.31,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "nope", "name": "No way", "about": "A stern shake, then turns away.", "starts": [],
      "beats": [
        {"duration":0.22,"look":[-0.6,0.1],"mood":"mean"},
        {"duration":0.22,"look":[0.6,0.1],"mood":"mean"},
        {"duration":0.46,"look":[0.75,0.05],"mood":"mean","tilt":6}
      ] },
    { "id": "hmm", "name": "Hmm…", "about": "Looks up, deep in thought.", "starts": [],
      "beats": [
        {"duration":0.9,"look":[0.35,-0.7],"mood":"thinking","tilt":-5}
      ] },
    { "id": "aha", "name": "Aha!", "about": "Thinks, then a light bulb and a hop.", "starts": [],
      "beats": [
        {"duration":0.46,"look":[0.3,-0.7],"mood":"thinking"},
        {"duration":0.44,"glyph":"idea","hop":true,"look":[0,0.1],"mood":"surprised"}
      ] },
    { "id": "tada", "name": "Ta-da!", "about": "Gasps, then hops proudly.", "starts": [],
      "beats": [
        {"duration":0.34,"look":[0,0.1],"mood":"surprised"},
        {"duration":0.56,"hop":true,"look":[0,0.1],"mood":"happy","tilt":-6}
      ] },
    { "id": "sorry", "name": "Sorry", "about": "A low bow, then a sad face.", "starts": [],
      "beats": [
        {"duration":0.37,"look":[0,0.8]},
        {"duration":0.53,"look":[0,0.4],"mood":"sad"}
      ] },
    { "id": "oops", "name": "Oops", "about": "Startles, winces, then looks away sheepishly.", "starts": [],
      "beats": [
        {"duration":0.32,"glyph":"exclaim","look":[0,0.1],"mood":"surprised"},
        {"duration":0.33,"look":[-0.3,0.3],"mood":"error"},
        {"duration":0.25,"glyph":"sweat","mood":"shy"}
      ] },
    { "id": "impressed", "name": "Impressed", "about": "Wide eyes, then a happy squint.", "starts": [],
      "beats": [
        {"duration":0.45,"glyph":"exclaim","look":[0,0.1],"mood":"surprised"},
        {"duration":0.45,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "haha", "name": "Haha", "about": "Rocks with laughter.", "starts": [],
      "beats": [
        {"duration":0.34,"hop":true,"look":[0.1,-0.2],"mood":"happy","tilt":-6},
        {"duration":0.34,"look":[0,0.1],"mood":"happy","tilt":6},
        {"duration":0.22,"look":[0,0.1],"mood":"happy","tilt":-3}
      ] },
    { "id": "loveIt", "name": "Love it", "about": "Hearts and a happy tilt.", "starts": [],
      "beats": [
        {"duration":0.9,"look":[0,0.1],"mood":"love","tilt":5}
      ] },
    { "id": "sadNews", "name": "Bad news", "about": "Looks down, sad.", "starts": [],
      "beats": [
        {"duration":0.9,"look":[0,0.5],"mood":"sad"}
      ] },
    { "id": "careful", "name": "Careful!", "about": "Startles and warns you.", "starts": [],
      "beats": [
        {"duration":0.34,"glyph":"exclaim","hop":true,"look":[0,0.1],"mood":"surprised"},
        {"duration":0.56,"glyph":"exclaim","look":[0,0.1]}
      ] },
    { "id": "welcome", "name": "You're welcome", "about": "A little bow and a smile.", "starts": [],
      "beats": [
        {"duration":0.37,"look":[0,0.7]},
        {"duration":0.52,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "confused", "name": "Confused", "about": "Tilts its head one way, then the other, puzzled.", "starts": [],
      "beats": [
        {"duration":0.36,"glyph":"question","look":[-0.3,-0.2],"mood":"curious","tilt":-12},
        {"duration":0.36,"glyph":"question","look":[0.3,-0.2],"mood":"curious","tilt":2},
        {"duration":0.19,"look":[0,0.1]}
      ] },
    { "id": "phew", "name": "Phew", "about": "A nervous sweat, then a big sigh of relief.", "starts": [],
      "beats": [
        {"duration":0.35,"glyph":"sweat","look":[0.2,0.3],"mood":"scared","stretch":0.05},
        {"duration":0.36,"look":[0,0.4],"mood":"content","stretch":-0.1},
        {"duration":0.19,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "smug", "name": "Smug", "about": "Chin up, eyes closed, very pleased with itself.", "starts": [],
      "beats": [
        {"duration":0.33,"look":[0,0.1]},
        {"duration":0.57,"look":[0.15,-0.5],"mood":"content","stretch":0.04,"tilt":7}
      ] },
    { "id": "twirl", "name": "Twirl", "about": "Spins its gaze all the way round, sparkling.", "favoriteColor": true, "starts": [],
      "beats": [
        {"duration":0.13,"look":[0,0.4],"mood":"excited","stretch":-0.05},
        {"duration":0.12,"glyph":"sparkles","look":[0.9,0.1],"mood":"excited","tilt":8},
        {"duration":0.12,"glyph":"sparkles","look":[0,-0.85],"mood":"excited"},
        {"duration":0.12,"glyph":"sparkles","look":[-0.9,0.1],"mood":"excited","tilt":-8},
        {"duration":0.12,"glyph":"sparkles","look":[0,0.7],"mood":"excited"},
        {"duration":0.12,"glyph":"sparkles","look":[0.9,0.1],"mood":"excited","tilt":8},
        {"duration":0.12,"glyph":"sparkles","look":[0,-0.85],"mood":"excited"},
        {"duration":0.06,"glyph":"sparkles","look":[0,0.1],"mood":"happy","stretch":0.06}
      ] },
    { "id": "serenade", "name": "Serenade", "about": "Hums a love song, hearts drifting up.", "favoriteColor": true, "starts": [],
      "beats": [
        {"duration":0.26,"look":[0,-0.3],"mood":"content"},
        {"duration":0.26,"glyph":"notes","look":[-0.3,-0.35],"mood":"love","tilt":-7},
        {"duration":0.26,"glyph":"notes","look":[0.3,-0.35],"mood":"love","tilt":7},
        {"duration":0.13,"glyph":"heart","look":[0,0.1],"mood":"love","tilt":-3}
      ] },
    { "id": "cheer", "name": "Cheer", "about": "Three happy hops in a row.", "favoriteColor": true, "starts": [],
      "beats": [
        {"duration":0.26,"hop":true,"look":[0,-0.3],"mood":"happy","tilt":-6},
        {"duration":0.26,"glyph":"sparkles","hop":true,"look":[0,-0.3],"mood":"excited","tilt":6},
        {"duration":0.26,"glyph":"sparkles","hop":true,"look":[0,-0.35],"mood":"happy","tilt":-6},
        {"duration":0.13,"look":[0,0.1],"mood":"content"}
      ] },
    { "id": "swoon", "name": "Swoon", "about": "Melts into a puddle of hearts and a dreamy tilt.", "favoriteColor": true, "starts": [],
      "beats": [
        {"duration":0.26,"look":[0.2,-0.3],"mood":"surprised"},
        {"duration":0.26,"glyph":"heart","look":[0.35,-0.2],"mood":"love","stretch":-0.08,"tilt":9},
        {"duration":0.26,"glyph":"heart","look":[0.3,-0.1],"mood":"content","stretch":-0.1,"tilt":6},
        {"duration":0.13,"look":[0,0.1],"mood":"happy"}
      ] },
    { "id": "glow", "name": "Glow", "about": "Stretches tall and proud, sparkling from head to horn.", "favoriteColor": true, "starts": [],
      "beats": [
        {"duration":0.31,"look":[0,-0.2],"mood":"content","stretch":0.04},
        {"duration":0.4,"glyph":"sparkles","look":[0.1,-0.55],"mood":"happy","stretch":0.14},
        {"duration":0.19,"look":[0,0.1],"mood":"content","stretch":0.04}
      ] }
  ]
}"###;
