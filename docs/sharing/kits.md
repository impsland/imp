# Kit format reference

A kit is one JSON file, the same format Imp exports (see [Sharing setups](/sharing/setups)).
The Den checks every kit it receives against the same limits and rules (see
`spec/PROTOCOL.md`). This page lists the fields for animations and an Imp's
character, for anyone who writes a kit by hand.

## How a kit is recognised

A kit has no version number. It is a JSON object with at least one of `imps`, `triggers`,
`animations` or `mcpServers`, and optionally `name`, `about` and `app` (the Imp that wrote it,
informational). Imp also takes a bare trigger or a plain MCP snippet. Unknown keys are ignored, so
adding fields is safe. A change that an older Imp would misread uses a new key, so the older Imp
leaves it out or refuses the kit.

## Animations and traits

A kit can carry custom animations, at the top level (shared by the whole kit) and inside any Imp
(`"animations"`, that Imp's own). Each animation has a `name` (required, at most 40 characters), and
optional `about`, `symbol` (an SF Symbol), `replaces` (the id of a built-in
animation, such as `yawn` or `jump`) and `starts` (what starts it: `idle`, `poke`, `circle`, `swish`,
`stroke`, `favoriteColor`, `tickle`, `hold`, `pickUp`, `shake`, `drop`, `rush`, `linger`, `stare`,
`dangle`, `comeback`). An animation that starts a gesture takes it over from the built-in animation that had it, and the built-in one returns when that animation is removed. It plays a list of `beats`, each with a `duration` in seconds (0.05 to 6,
required) and optionally `look` (`[x, y]`, each -1 to 1), `mood`, `glyph` (`notes`, `question`,
`exclaim`, `idea`, `sweat`, `heart`, `sparkles`), `tilt` (-30 to 30 degrees), `hop`, `stretch`
(-0.3 to 0.3) and `move` (`spin`, `flip`, `roll`, `bounce`, `shake`, `sway`, `wobble`, `float`, `nod`,
`headshake`, played across the beat) with `times` (1 to 8) and `reverse` (true or false). `mood` is one of idle, listening, thinking, happy, love, sad, error, sleepy, annoyed,
surprised, dizzy, mean, working, content, giggly, scared, curious, shy, excited, bored.

An Imp may also have `traits`: `lids` 0 to 0.6, `slant` -1 to 1 (negative worried, positive angry),
`eyes` -0.4 to 0.4, `squint` -1 to 1, `horns` -30 to 30 degrees, `blush` 0 to 1, `tilt` -12 to 12 and
`tempo` 0.6 to 1.6 (animation speed).

The Den checks the limits: 1 to 24 beats per animation, at most 20 s in total, known moods and
glyphs, and at most 50 animations per kit. An example with animations is
`spec/fixtures/kits/moody-moves.json`.
