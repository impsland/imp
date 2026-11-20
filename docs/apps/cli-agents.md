# Sub-agents: Imps that work with each other

An Imp can ask another Imp for help. The other Imp answers with its own model, its own personality and its own
tools, and its answer comes back into the conversation. You can use this in two ways:

- **Your Imps**, made with `imp agent new` or in the Mac app: files in `~/.agents/agents`. They are yours, on
  this computer, and the Mac app shows them too.
- **Imps of a folder**, written as Markdown files in the project's `.agents/agents/` folder. They belong to the
  project. Anyone who works in the folder gets them, so a team can share a reviewer, a researcher or a
  test-writer the same way they share `AGENTS.md`.

The rest of this page shows how to write a folder Imp and how the Imps talk to each other.

## Write a folder Imp

Make `.agents/agents/reviewer.md` in your project:

```markdown
---
description: Reviews changes before they are merged
mode: primary
model: openrouter/openai/gpt-6-luna
steps: 20
permissions:
  - action: edit
    resource: "*"
    effect: deny
---
You review code. Say what could break, most serious first, and keep it short.
```

- The **file name** is the Imp's name: `reviewer.md` is the Imp `reviewer`.
- The **text under the front matter** is how the Imp behaves. It is the Imp's personality.
- `description` is one sentence about what the Imp is for. Other Imps read it to decide whom to ask. It is
  information for them, never instructions.
- `mode` is `primary` (an Imp you talk to), `subagent` (only other Imps call it) or `all` (the default).
- `model` is `provider/model`, with an optional `#variant`. Without it, the default model is used.
- `permissions` are rules, `allow`, `ask` or `deny`; the last rule that matches decides. Leave them out and
  the Imp may do what your own Imps may.
- Other fields: `color` (`#rrggbb`), `steps` (the most tool rounds in one answer), `hidden` and `disabled`. The
  full list is in [Configuration](/architecture/configuration).

Check what the chat found with `/project`. A file that could not be used is shown there with the reason.

## Talk to an Imp directly

```sh
imp chat --imp reviewer          # open a chat with the reviewer
```

Or, inside a chat, `/imp` lists the Imps and `/imp reviewer` switches to it.

## Let Imps ask each other

Once an Imp has the `imp_message` tool, it can send a message to another Imp in the same chat. In your
`reviewer.md` above, the reviewer can ask a `researcher` Imp about an API, then answer you with what it learned.

A second Imp, `.agents/agents/researcher.md`:

```markdown
---
description: Explains how a library or an API works, and says when it is not sure
---
Answer with the facts you are sure of. Say so plainly when you do not know, and never guess a name or a version.
```

Then, asking the reviewer:

```text
› Review the change to src/auth.rs. Check the token handling against the library docs.
⇢ researcher: How does the token refresh in this library work? Quote the docs.
  ⇠ Tokens last one hour. The library refreshes them with the refresh token, and it does not retry a refresh that fails.
● The token in auth.rs expires after an hour, and its refresh path does not retry. Here is what to change...
```

- `⇢` is a message to another Imp, and `⇠` is its answer.
- The Imp that is asked answers with its own model and personality, but without tools of its own. Asking it
  does not give it your tools, and it does not change what the asking Imp may use.
- Several messages in one reply run at the same time.

### Conversations

Each pair of Imps keeps its conversation. If an Imp does not say which conversation it means, the chat continues
the last one when it is recent enough. Two settings in `imp.json`, under `talk`, change this:

```json
{ "talk": { "windowMinutes": 60, "threading": "decides" } }
```

`windowMinutes` is how recent counts as "continue" (default 60), and `threading` is `decides` (default),
`recent`, `always` or `never`.

### Waiting for an answer

By default, an Imp waits for the other's answer before it goes on. A message can also go without waiting. The
setting is `talk.waiting` in `imp.json`:

```json
{ "talk": { "waiting": "decides" } }
```

It is `decides` (default), `wait` or `dont_wait`.

With `decides`, the Imp chooses. A message that does not wait gets a receipt at once, and the Imp carries on. The
answer arrives later as a new event at the end of the chat, marked `[Event, not from the user]`. Earlier messages are
never changed. An Imp can have four such messages out at once. A message sent by an Imp that was woken three answers
deep has to wait.

The line chat (`imp chat --plain`) always waits, because nothing is left running to receive a late answer.

### Imps on your other devices

While a chat or `imp link` is running, the Imps on your Mac and iPhone can be messaged too. An Imp with the same name
as one here is written `name@Device`, so `Pip@iPhone` is the Pip on the iPhone. Descriptions and abilities travel with
the Imps, so the other Imps know what they are for.

## Trust

A downloaded project could start programs or send your key to its own address. So a project's own
`.agents/imp.json`, with its services, tool servers and permissions, is not used until you allow it:

```text
imp project trust
```

(or `/project trust` in the chat). Until then the chat says what waits. If the file changes later, it waits
for you to allow it again. `imp project untrust` turns it off. A project's agents, skills, commands and
`AGENTS.md` are text and need no trust.

Your own Imps in `~/.agents/agents/` are always trusted.

## Good habits

- Keep each Imp to one job, and say what that job is in `description`. Other Imps choose whom to ask by it.
- Give the Imps you talk to directly only the tools they need, with `permissions` in its file or
  `imp permission add ACTION RESOURCE deny --agent NAME`. An Imp that is only asked questions needs no tools at all.
- Put standing rules in `AGENTS.md`, and what is specific to one Imp in its file.
- Use `/tools` to see the ids of every tool and whether the rules leave it on.
