# First run

A new user goes from the first launch to the first answer from an Imp in a short, friendly path.

## Decision

The path feels like waking the Imp up, not like filling in a form. It is one modal flow of three steps on the Mac (the iPhone follows in a later release), and the user only presses Next. No step asks for anything in a build that comes with a model service (see "A service that comes with the app" in `docs/guide/services.md`).

1. **Your Imp has a brain** (`onboarding.step.model`). One plain sentence says what the model is for (`onboarding.model.body`). The picture shows the Imp on one side and a brain on the other: the key leaves the brain and a line is drawn to the Imp once it is connected, with the service's host small under the brain (`onboarding.model.ready`). The key is issued while the step shows (`onboarding.model.issuing`). The key goes where a typed key goes, and the service is preset: its address, the first model it lists and its host as the name. A failure is a calm card (`onboarding.retry.title`) with Try again, the wait the service asked for (`onboarding.retry.wait`) and the technical answer tucked in "Details". In a build with no service, or after "Change connection" (`onboarding.change_connection`), the step holds the form from the old first run: Remote or Local, address, key and model, with the same check. Next runs the check and moves on once it passes.
2. **Send your Imp to another screen** (`onboarding.step.move`). It explains the quick swipe toward the edge of the screen that carries an Imp to another device. The picture shows the Imp flung off one device, leaving a short trail along an arc, and landing on the outline of the other. On the Mac it goes from the Mac window to a phone, on the iPhone from the phone to a Mac.
3. **Let your Imp set itself up** (`onboarding.step.setup`). The Imp has a speech bubble above it and the prompt is typed into the bubble, then five emotions appear one by one. The prompt is in plain everyday words, with no tool names or ids: "Hi! Make 5 animations for different emotions. And when I click on you, open the box where I can type to you." (`onboarding.prompt`, and `onboarding.prompt.tap` with "tap" on the iPhone). The Imp finds its own tools. The prompt is editable and comes back with "Setup prompt" (`onboarding.setup_prompt`) in the Brain panel of the Imp's settings, where it can be changed and sent again.

The Imp is created only by Next on step 3, and starts on the prompt at once. Closing creates nothing. Back goes one step back. The pictures hold still with Reduce Motion. An animation the Imp makes does not play by itself when it is saved: the Imp shows it when asked or when a trigger plays it.

**Where the choices come from.** Remote and Local are data, not code: `spec/presets/services.json` lists each one's name, symbol, address and link, and which is picked first. `node design/generate.mjs` compiles the file into the apps, like the animation catalog. Changing an address or a link is an edit of that file.

**Moving.** The top bar has Back (leading icon, hidden on step 1), the step indicator in the centre and Close (trailing icon). Back goes one step back. The indicator jumps to a step already completed, never forward past an unmet requirement: step 2 needs models loaded for the address and key as they are now. Nothing jumps while a request runs. Close dismisses at any time and leaves the Imp asleep, a calm valid state. There is no "Later" and no "skipped" screen. What the user typed survives every move between steps. Return presses the one primary button, Esc closes.

The Imp on top reacts: asleep, stirring while it checks, awake once it works. Steps change with the `scene` motion (a plain fade with Reduce Motion). Focus goes to the first empty field. The Brain section and the "Give {name} a Brain" button on a sleeping Imp open the flow again at any time.

## Why

- "Wake the Imp" is a story people understand at once. Nothing says "configuration".
- Two named steps show where the user is and what each asks. The indicator makes them interactive instead of a label.
- Remote or Local is the one question a newcomer can answer. Both fill an address that stays editable, so any OpenAI-compatible API works, LM Studio included, without a list of products to read.
- Closing is safe. No Imp is a calm state, and so is a sleeping one whose triggers still work.
- The service choice and the address and key fields are one component with the "Add a service" sheet, so the two cannot drift apart. "Add a service" offers the same two choices and nothing more.
- The flow ends when the Imp is awake. The Imp is then ready to talk to where it lives (its bubble on the Mac, its chat on the iPhone).

## Rejected

A long wizard with a page for each setting. It feels like a form. A "Later" button: Close already does that, and a second way out is noise. Hard-coding one service. Asking for a hosted account: there is no hosted model yet. A grid of named products (OpenRouter, Ollama, LM Studio, OmniRoute) and "Other": five choices that newcomers had to tell apart, when the address already accepts any of them. LM Studio and OmniRoute are not presets in the first run or in "Add a service": their users type or paste their address into Local's field. A third step, "Say hello to Imp", with a ready-made first message: the Imp is already awake when the check works, and the step asked for a message nobody needed to write there.

## On the iPhone

The steps and words are the same, with both choices. Local is a server on another computer, because an iPhone cannot look at its own localhost, so its address is filled with a host to replace (`firstrun.service.host_note`). The first screen has two halves. On top, one sleeping Imp says what it needs in its own speech bubble (the stage's bubble, its tail pointing at it). It leans as the phone tips, stirs at a touch and hops when tapped. Under it, "Meet Imp" (`phone.start.title`) and one sentence about what Imp is. In the thumb zone, two ways to begin, in order of weight: a wide main button that wakes it (`firstrun.wake`) with one line on what that needs (`phone.start.wake_note`), and a card that links a device (`phone.start.link_title`, with what it brings in one line, opening its own sheet with this iPhone's code, Scan a Code, Paste Link and this iPhone's name). There is no separate Hatch: waking makes the first Imp, and `+` in the room makes the next ones. The parts fade in one after the other, once, and only fade with Reduce Motion. The very first Imp is hatched by the main button and meets the flow in one sheet with the live Imp on top (Close leaves it asleep). The sheet wears the Imp's colour. Any later Imp without a Brain is dimmed, with no words over it. "Wake {name} up" in its chat opens the Imp's settings on the Brain, the same form in place, not this sheet. On the iPhone the flow is one screen with no step numbers: Remote or Local, then the address, the key and the model together, and one button. A blank model is picked for you (the first one that chats). The list button beside the field shows the service's models to choose from, and any name can be typed. An Imp keeps its Brain the moment it wakes. The key field never offers a password manager.

![The model step](./images/onboarding-model.png)

## On the Mac

There is no premade Imp. A fresh install has an empty troupe, and nothing is created before the flow ends. On the first launch, with no Imp and the first run not yet seen (`firstRunSeen`), the home window opens on its empty canvas with the first run over it, once. The sheet has the step's picture on top, the step title and its number, what the step says, and in the footer Back, the compact `firstrun.link` button on step 1 (it brings an Imp from another device and closes the sheet when one arrives) and Next, the default button.

The "Brain" panel of an Imp has two quiet buttons, "Change connection" (the form from the old first run, with its check) and "Setup prompt" (the prompt, to change or to send to the Imp again).

## Errors in this path

Every error is a plain sentence that says what to do next. It shows in place and keeps what the user typed.

| What happened | Key |
| --- | --- |
| The address is not an http or https address | `firstrun.error.address` |
| The key field is empty | `firstrun.error.empty_key` |
| No model is picked | `firstrun.error.no_model` |
| The key was refused | `error.brain.key` |
| The service does not answer | `error.brain.unreachable` |
| The service is too slow | `error.brain.timeout` |
| The model does not exist | `error.brain.model` |
| No local server answered | `error.brain.local` |

## States

| State | What is shown |
| --- | --- |
| Service | Remote and Local, address, key, Continue. |
| Loading models | `firstrun.service.loading`, the fields wait. |
| Model | The list and the model field, `firstrun.wake`. |
| Checking | `firstrun.check.running`, the Imp stirs. |
| Failed | An error sentence and `common.try_again`, on step 2. |
| Awake | `firstrun.check.ok`. The Imp keeps its Brain and the flow ends by itself. |
| Done | The flow closes. The Imp is awake. |

## Words

<!-- strings: firstrun -->
| Key | English |
| --- | --- |
| `firstrun.asleep_bubble` | {name} is asleep. Give it a Brain to wake it up. |
| `firstrun.check.ok` | {name} is awake. |
| `firstrun.check.running` | Waking {name} up… |
| `firstrun.error.address` | That address does not look right. It starts with https:// or http://. |
| `firstrun.error.empty_key` | Paste your key to continue. |
| `firstrun.error.key_not_saved` | Imp could not save the key. Try again. |
| `firstrun.error.no_model` | Pick a model to continue. |
| `firstrun.link` | From a device |
| `firstrun.link.help` | Link a device and bring an Imp from it instead |
| `firstrun.model.search` | Search or type a model |
| `firstrun.service.address` | Address |
| `firstrun.service.found` | Found on this Mac |
| `firstrun.service.host_note` | Use the address of your computer on this network. |
| `firstrun.service.key` | Your key |
| `firstrun.service.key_local` | Not needed for local models |
| `firstrun.service.kind` | Kind of service |
| `firstrun.service.loading` | Loading models… |
| `firstrun.service.local` | Local |
| `firstrun.service.note` | Any OpenAI-compatible API. Your key stays on this device. |
| `firstrun.service.remote` | Remote |
| `firstrun.step.model` | Model |
| `firstrun.step.service` | Service |
| `firstrun.wake` | Wake {name} up |
<!-- /strings -->
