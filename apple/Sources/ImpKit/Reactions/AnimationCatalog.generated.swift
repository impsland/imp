// generated from spec/animations/catalog.json, do not edit. Run: node design/generate.mjs

extension AnimationCatalog {
    /// The bundled animations as catalog JSON. Compiled in, so no resource bundle has to be found at run time.
    static let bundledJSON = #"""
{
  "name": "Imp animations",
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
    {
      "id": "greet",
      "name": "Nod hello",
      "about": "A friendly double nod.",
      "bundled": true,
      "starts": [],
      "beats": [
        {
          "duration": 0.2,
          "look": [
            0,
            0.5
          ]
        },
        {
          "duration": 0.2,
          "look": [
            0,
            0.1
          ]
        },
        {
          "duration": 0.2,
          "look": [
            0,
            0.45
          ]
        },
        {
          "duration": 0.3,
          "look": [
            0,
            0.1
          ],
          "mood": "happy"
        }
      ]
    },
    {
      "id": "smile",
      "name": "Smile",
      "about": "Happy squinty eyes.",
      "bundled": true,
      "starts": [
        "idle"
      ],
      "beats": [
        {
          "duration": 0.9,
          "look": [
            0,
            0.1
          ],
          "mood": "happy"
        }
      ]
    },
    {
      "id": "sad",
      "name": "Sulk",
      "about": "Looks down and sulks.",
      "bundled": true,
      "starts": [],
      "beats": [
        {
          "duration": 0.9,
          "look": [
            -0.2,
            0.5
          ],
          "mood": "sad"
        }
      ]
    },
    {
      "id": "wow",
      "name": "Gasp",
      "about": "Eyes wide, an exclamation mark.",
      "bundled": true,
      "starts": [],
      "beats": [
        {
          "duration": 0.9,
          "glyph": "exclaim",
          "look": [
            0,
            0.1
          ],
          "mood": "surprised"
        }
      ]
    },
    {
      "id": "sleep",
      "name": "Doze",
      "about": "Nods off for a moment.",
      "bundled": true,
      "starts": [],
      "beats": [
        {
          "duration": 0.9,
          "look": [
            0,
            0.35
          ],
          "mood": "sleepy"
        }
      ]
    }
  ]
}
"""#
}
