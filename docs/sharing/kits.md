# Kit format reference

A kit is one JSON file, the same format Imp exports (see [Sharing setups](/sharing/setups)).
Kits follow the limits and rules in
`spec/PROTOCOL.md`; a gallery such as the Den checks them too. This page lists the fields for animations and an Imp's
character, for anyone who writes a kit by hand.

## How a kit is recognised

A kit is a JSON object with at least one of `imps`, `triggers`,
`animations`, `mcpServers` or `skills`, and optionally `name`, `about`, `format` (the kit format, 1; missing means 1) and `app` (the Imp that wrote it,
informational). Imp also takes a bare trigger or a plain MCP snippet. Unknown keys are ignored, so
adding fields is safe. A kit in a newer `format` than the Imp reads is refused.

## Triggers

A trigger is **one event, optional conditions, and one to five steps**. It is the only way anything
happens on its own: there are no built-in reactions, and an animation never starts by itself. The same
object is used in kits and by the Imp's own tool `imp_add_trigger`.

```json
{ "name": "Ouch", "on": "poke",
  "if": [ { "state": "hours", "value": "09:00-18:00" } ],
  "do": [ { "act": "play", "value": "Wiggle" }, { "act": "say", "value": "Ouch!" } ] }
```

| field | rule |
|-------|------|
| `name` | 1 to 60 characters. |
| `on` | One event from the table below. |
| `value` | The event's one argument, when it has one (a number or a word, as the table says). |
| `if` | Optional. Conditions that must all hold at that moment: `{ "state", "value" }`. |
| `do` | 1 to 5 steps, run in order: `{ "act", "value" }`, plus the extras the table names. |
| `enabled` | Optional, `true` by default. |

### Events (`on`)

| event | `value` | happens when |
|-------|---------|--------------|
| `keys` | Keys, such as `"ctrl+cmd+T"`. Required. | The person presses them anywhere. |
| `click` | Clicks in a row, 1 to 3. Default 1. | The person clicks the Imp. |
| `poke`, `hold`, `drag`, `drop`, `shake`, `stroke`, `tickle`, `circle`, `swish`, `rush`, `dangle` | none | The person does that to the Imp with the pointer: four quick clicks, press and hold, drag it, let go, shake it while dragging, stroke its head, jiggle on its head, circle it, swish past its face, rush at it, bob above its head. |
| `near` | Seconds the pointer rests next to the Imp. Default 0. | The pointer comes close (and stays that long). |
| `away` | none | The pointer moves away from the Imp. |
| `start` | none | Imp starts. Also right when the trigger is made or switched on. |
| `at` | A time, `"HH:MM"`. | Every day at that time. Add a `days` condition for some days only. |
| `every` | Minutes, 1 to 1440. | Every so many minutes. |
| `idle` | Seconds, 5 to 86400. | Nobody has touched or talked to the Imp for that long. |
| `back` | Minutes away. Default 5. | The person comes back to the keyboard or mouse. |
| `wake` | none | The Mac wakes up or unlocks. |
| `app` | An app's name or bundle ID. Empty: any app. | That app comes to the front. |
| `website` | Part of the address. | The browser shows such a page (needs the browser extension). |
| `battery` | Percent, default 20. | The battery drops below it. |
| `charger` | `"plugged"` or `"unplugged"`. | The charger is plugged in or out. |
| `busy` | Percent, default 85. | The processor stays above it for a while. |
| `hot` | none | The Mac runs hot. |
| `network` | `"offline"` or `"online"`. | The network goes away or comes back. |

### Conditions (`if`)

`{ "state": <name>, "value": <value> }`. The states `battery` (below that percent), `charger`, `app`
(in front), `website` (shown), `busy`, `hot` and `network` read their `value` as the event of the same
name does. Three more:

| state | `value` |
|-------|---------|
| `hours` | `"22:00-07:00"`: between those times (it may wrap past midnight). |
| `days` | `"mon-fri"` or a list such as `"sat,sun"`. |
| `asleep` | `true` or `false`: whether the Imp is asleep. |

### Steps (`do`)

| `act` | `value` | extras | what it does |
|-------|---------|--------|--------------|
| `ask` | What the Imp should do, in plain words to itself. | `clipboard: true` hands over what the person copied. | The Imp's model gets it with what happened and answers with its tools. Needs a Brain. |
| `say` | Text. | — | Shows the text in the bubble. No Brain needed. |
| `play` | An animation's name. | | Plays it. |
| `sleep` | Optional animation to play while falling asleep. | | Falls asleep. |
| `wake` | Optional animation to play while waking. | | Wakes up. |
| `follow` | `off`, `eyes`, `hop` or `glide`. | `speed`: 0.5 to 2, 1 is normal. | How the Imp follows the pointer from now on (Mac only). Without any, its eyes follow and it stays put. |
| `open` | `text_box`, `listen`, `chat` or `settings`. | | Opens that for the person. |

Rules:

- Steps run in order and at once. `ask` hands its work to the model and the next steps don't wait for it.
- When several triggers match one event, all of them run, in list order.
- A trigger with an `ask` step that something other than the person set off (not `keys`, `click` or a
  pointer gesture) rests 60 seconds after it runs, so the model is not flooded. Triggers without `ask`
  never rest.
- Triggers live on the Mac. The iPhone and the terminal have none.

## Animations and traits

A kit can carry custom animations, at the top level (shared by the whole kit) and inside any Imp
(`"animations"`, that Imp's own).

- `name` (required, at most 40 characters).
- `about`, `symbol` (an SF Symbol).
- Nothing starts an animation by itself. A trigger with a `play` step does (for example `on: poke`).
- `beats`: a list. Each beat has a `duration` in seconds (0.05 to 6, required) and optionally:
  - `look`: `[x, y]`, each -1 to 1.
  - `mood`: one of `idle`, `listening`, `thinking`, `happy`, `love`, `sad`, `error`, `sleepy`, `annoyed`,
    `surprised`, `dizzy`, `mean`, `working`, `content`, `giggly`, `scared`, `curious`, `shy`, `excited`, `bored`.
  - `glyph`: one of `notes`, `question`, `exclaim`, `idea`, `sweat`, `heart`, `sparkles`.
  - `tilt`: -30 to 30 degrees. `hop` and `stretch` (-0.3 to 0.3).
  - `move`: one of `spin`, `flip`, `roll`, `bounce`, `shake`, `sway`, `wobble`, `float`, `nod`, `headshake`,
    played across the beat, with `times` (1 to 8) and `reverse` (true or false).

An Imp may also have `traits`:

| Trait | Range | Meaning |
|-------|-------|---------|
| `lids` | 0 to 0.6 | Eyelids |
| `slant` | -1 to 1 | Negative is worried, positive is angry |
| `eyes` | -0.4 to 0.4 | Eyes |
| `squint` | -1 to 1 | Squint |
| `horns` | -30 to 30 degrees | Horns |
| `blush` | 0 to 1 | Blush |
| `tilt` | -12 to 12 | Tilt |
| `tempo` | 0.6 to 1.6 | Animation speed |

The limits are: 1 to 24 beats per animation, at most 20 s in total, known moods and
glyphs, and at most 50 animations per kit. An example with animations is
`spec/fixtures/kits/moody-moves.json`.
