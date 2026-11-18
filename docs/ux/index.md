# UX specification

This is the one description of how Imp looks and behaves. It covers every screen, every state, every animation and every word. The apps on every platform follow it. The look stays native to each platform. The screens, the states, the words and the behavior stay the same.

Design comes first. A screen is built after its page here is written.

## How the pages are laid out

Each page has the same parts:

- **Decision.** What we do.
- **Why.** The reasons, short.
- **Rejected.** The option we looked at and did not take.
- **States.** Every state the screen can be in, with the words it shows. Words are named by string key. The table under each state group shows the English text. All three languages are on [All words](/ux/strings).

## The pages

| Page | What it covers |
| --- | --- |
| [Main screen](/ux/main-screen) | The calm canvas, the window, the one quiet button, menus and the background. |
| [Imps](/ux/imps) | Moving an Imp, letting it out, sending it home, clicks, the phone icon and peeking. |
| [Imp Settings](/ux/imp-settings) | The settings of one Imp, with the Imp in the middle. |
| [All Imps settings](/ux/all-imps-settings) | The app-wide settings: nine sections, each one click from any other. |
| [First run](/ux/first-run) | From the first launch to the first answer. |
| [States](/ux/states) | Empty, error, sleeping, waking, offline and partly set up servers. |
| [Motion](/ux/motion) | Timings, springs and what Reduce Motion does. |
| [Accessibility](/ux/accessibility) | Keyboard, screen readers, text size, contrast and touch targets. |
| [Platforms](/ux/platforms) | How each screen maps to macOS, iPhone, Android, Windows and Linux. |
| [Parity](/ux/parity) | A table of screens and states by platform. |
| [All words](/ux/strings) | Every user-facing word, by key, in English, Spanish and Simplified Chinese. |

## Where things come from

- **Colors, spacing, radii, type sizes, touch targets, timings and behavior numbers** are in `design/tokens.json`. `node design/generate.mjs` writes the Swift, Kotlin, C#, GTK and web files from it. See [Design](/design/).
- **Words** are in `design/strings`, each with a stable key like `home.empty.new_imp` and its English, Spanish and Simplified Chinese text. The same generator writes the Apple String Catalog, Android `strings.xml`, Windows `.resw` and GTK `.po` files.
- **Terms** are defined in the [Glossary](/glossary). Use them the same way in the UI, the docs and the code.

Views are written by hand with each platform's own tools. Only tokens and strings are generated.

## Words on every platform

- Keys are lowercase, with dots: `area.thing.detail`. A key never changes its meaning. A new meaning gets a new key.
- A word in curly brackets, like `{name}`, is filled in by the app. Translations keep every one of them. A plural has an `other` form and often a `one` form.
- On Apple the key is looked up in the String Catalog. For text with a value, read it with the key and fill it in with `String(format:)`. For a plural, use `String.localizedStringWithFormat`.
- **One pipeline.** Every new or changed word of a screen gets a key in `design/strings`, with all three languages, and the Swift code names the key (`Text("key")`, `words("key", value)`). An English sentence used as its own key in Swift is older text: it stays in the String Catalog, kept by `make strings`, until its screen is next changed, and then moves to `design/strings`. `make strings` marks words no code uses any more as stale.
- On Android the key's dots become underscores (`home.empty.new_imp` is `home_empty_new_imp`).
- On Windows the key is kept and read with slashes (`home/empty/new_imp`). A plural has one string per form: `.one` and `.other`.
- On Linux the key is the gettext context and the English text is the message.

## Writing rules for the words

- Plain, friendly, short sentences.
- No semicolon inside a sentence. No long dash. Use a comma, a hyphen or a new sentence.
- An error says what happened and what to do next. It never shows a raw error name and never a blank bubble.
- Use the words from the glossary. It is "Brain", not "model settings". It is "Imp", not "agent" or "bot".
- The Hop is a name. In the middle of a sentence it reads "the Hop" in English.

## The common words

<!-- strings: common -->
| Key | English |
| --- | --- |
| `common.action_done` | Done |
| `common.action_failed` | Failed |
| `common.action_working` | Working |
| `common.add` | Add |
| `common.back` | Back |
| `common.cancel` | Cancel |
| `common.check` | Check |
| `common.choose` | Choose… |
| `common.clear` | Clear |
| `common.close` | Close |
| `common.continue` | Continue |
| `common.done` | Done |
| `common.help` | Help |
| `common.loading` | Loading… |
| `common.name` | Name |
| `common.needs_attention` | Needs attention |
| `common.off` | Off |
| `common.on` | On |
| `common.open` | Open |
| `common.remove` | Remove |
| `common.set_up` | Set up |
| `common.settings` | Settings |
| `common.step` | Step {number} of {total}, {name} |
| `common.try_again` | Try again |
| `common.undo` | Undo |
<!-- /strings -->
