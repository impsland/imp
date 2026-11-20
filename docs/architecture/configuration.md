# Configuration

The Mac app and the terminal app (`imp`) read and write one configuration. Set something up in one and the
other shows it: the same Imps, services, models, tool servers, permissions, skills and commands. Only what
belongs to a screen (windows, the bubble, colours of the app, where an Imp stands) stays with the app.

The core (`engine/src/config/`) owns the format: it finds the files, merges them, fills in variables,
evaluates permissions and writes changes. Both apps call it; neither parses these files itself.

## Where it lives

| What | Where | Shared |
| --- | --- | --- |
| Agents, skills, commands, `AGENTS.md` | `~/.agents/` and a project's `.agents/` | yes |
| Settings: services, the default model, tool servers, permissions, triggers, animations, requests, talk, link | `imp.json` in the config folder | yes |
| Keys and sign-ins | `auth.json` in the config folder, readable by you only (0600) | yes |
| Screens: windows, bubble, appearance, places on the canvas, which Imps are out | the app's own preferences | no |
| Chats, workspaces, the link's identity | each app's data folder | no |

The config folder is `$IMP_CONFIG_HOME`, else `$XDG_CONFIG_HOME/imp`, else `~/.config/imp` (on Windows
`%APPDATA%\imp`). The Mac app uses the same folder: it is not sandboxed, and one folder is what makes the
two apps one.

### Projects

The terminal app also reads the `.agents/` folder of every directory from where it starts up to the git
root (or the home folder). A nearer folder wins over a farther one, and a project wins over `~/.agents`, by
name: a project's `agents/review.md` replaces your `review` there. `AGENTS.md` files are all read, farthest
first. A project may have its own `.agents/imp.json` with services, tool servers and permissions; because
those start programs and send keys, they wait until you trust the project (`imp project trust`). Agents,
skills, commands and `AGENTS.md` are text and are read at once.

The Mac app reads `~/.agents` only: it has no current folder.

## Agents are Imps

An agent is a Markdown file, `agents/<name>.md`: front matter, then the system prompt.

```markdown
---
description: Reviews changes for correctness and regressions
mode: primary
model: ollama/qwen3.8#high
color: "#e0533d"
steps: 40
permissions:
  - action: triggers
    resource: "*"
    effect: deny
  - action: animations
    resource: "*"
    effect: allow
request:
  headers:
    X-Gateway-Tenant: engineering
---

Review the current changes.
```

| Field | Meaning |
| --- | --- |
| `description` | What it is good at, for people and for the other Imps (an Imp's About). |
| `mode` | `primary` (an Imp you talk to), `subagent` (only other Imps call it) or `all`. Default `all`. |
| `model` | `provider/model`, with an optional `#variant` (`low`, `medium`, `high`, or one the provider defines). Default: `model` in `imp.json`. |
| `variant` | The variant on its own, when `model` is inherited. |
| `color` | `#rrggbb`. The Imp's colour. |
| `steps` | The most tool steps in one answer. |
| `hidden` | Left out of lists. |
| `disabled` | Not loaded. |
| `permissions` | Rules, below. |
| `request` | `headers` and `body` added to every request this agent makes. |
| `system` | The prompt, when it is not the body. |

The name is the file name. Every `primary` or `all` agent in `~/.agents/agents` is an Imp in both apps;
`subagent` agents are listed but never stand on the desktop. What an Imp has that the format has no field
for (its character, size, favourite colour, memory settings, own animations, its id) is in `imp.json` under
`imps.<name>`, so the agent file stays readable by any tool that reads `.agents`.

Providers are not set in an agent file. An agent picks one by name in `model`; headers or body fields that
only this agent sends go in `request`.

## Permissions

A rule is an `action`, a `resource` pattern and an `effect`: `allow`, `ask` or `deny`. Rules are read in
order — the built-in defaults, `imp.json`'s `permissions`, the agent's `permissions` — and the last rule that
matches decides. `*` matches any run of characters, `?` one.

| Action | Resource | What it covers |
| --- | --- | --- |
| `personality`, `look`, `animations`, `triggers`, `tools`, `senses`, `computer` | a tool name, or `*` | The Imp's own tool groups (the switches in its settings). |
| `shell` | the command line | Running commands. |
| `mcp` | `<server>/<tool>` | Tools of MCP servers. `files/*` is every tool of `files`. |
| `skill` | the skill's name | Using a skill. |
| `read`, `edit` | a path | Reading and changing files (`~` is the home folder). |
| `message` | an Imp's name | Asking another Imp. |

`ask` asks you first: in the terminal as a prompt, on the Mac in the Imp's bubble (Allow once, Always,
Deny; Always adds an `allow` rule to the agent). The switches in an Imp's settings write these rules: a
group switched off is `{action: <group>, resource: "*", effect: deny}`.

## imp.json

```json
{
  "model": "openrouter/openai/gpt-6-luna",
  "providers": {
    "openrouter": { "name": "OpenRouter", "options": { "baseURL": "https://openrouter.ai/api/v1" } },
    "ollama": {
      "options": {
        "baseURL": "https://ollama.example.com/v1",
        "apiKey": "{env:OLLAMA_API_KEY}",
        "headers": { "X-Gateway-Tenant": "engineering" }
      },
      "models": { "qwen3.8": { "variants": { "high": { "reasoning_effort": "high" } } } }
    }
  },
  "mcp": {
    "files": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "~"] },
    "den": { "type": "remote", "url": "https://den.imp.land/mcp" }
  },
  "permissions": [{ "action": "shell", "resource": "rm -rf *", "effect": "deny" }],
  "imps": { "Pip": { "id": "7c0e…", "character": { … }, "size": 1.0, "memory": { "exchanges": 20 } } },
  "triggers": [ … ],
  "animations": [ … ],
  "requests": { "timeoutSeconds": 120, "retries": 3 },
  "talk": { … },
  "link": { "hop": "hop.example.com:4677", "deviceTools": { … } }
}
```

- A provider's key is `options.apiKey` when it is set (usually `{env:NAME}` or `{file:path}`), else the one
  saved for it in `auth.json`. Keys typed into either app are saved in `auth.json`, never in `imp.json`.
- `{env:NAME}` is replaced by the environment variable and `{file:path}` by the file's contents (`~` is the
  home folder), anywhere a string is allowed, in `imp.json` and in agent front matter.
- A variant's object is merged into the request body; `low`, `medium` and `high` work without one and send
  `reasoning_effort`.
- MCP servers are on for every Imp; a `deny` rule on `mcp` turns one off for an Imp.

## Skills and commands

A skill is `skills/<name>/SKILL.md` with a `name` (lowercase letters, digits and dashes, the folder's name)
and a `description`. Only names and descriptions go in the system prompt; the `skill` tool reads a skill
when a task needs it.

A command is `commands/<name>.md`, run as `/<name> …`. Front matter: `description`, `agent`, `model`,
`subtask`. The body is the message: `$ARGUMENTS` is everything after the name, `$1`, `$2`… one word each,
`` !`cmd` `` the output of a command (a `shell` permission), `@path` the contents of a file.

## Changing it

Everything that is not about a screen can be changed from the terminal, and the same things from a chat with
`/`:

| Terminal | Chat |
| --- | --- |
| `imp agent list \| show \| new \| edit \| set \| remove` | `/agent …` |
| `imp provider list \| add \| set \| remove`, `imp auth set \| clear` | `/provider …` |
| `imp model [provider/model#variant] [--agent NAME]` | `/model …` |
| `imp mcp list \| add \| set \| remove \| enable \| disable` | `/mcp …` |
| `imp permission list \| add \| remove [--agent NAME]` | `/permission …` |
| `imp skill list \| show`, `imp command list \| show` | `/skill`, `/command` |
| `imp project show \| trust \| untrust` | `/project …` |
| `imp config get \| set \| path` | `/config …` |

Writes are atomic (a temporary file, then a rename) and made under a lock (`imp.json.lock`), after reading
the file again, so the two apps never undo each other. The terminal app reads the files each time it needs them; the Mac app compares a cheap stamp of them (names, sizes and
modification times) every two seconds and reads again when it changed (see below).

## How the Mac app maps it

The Mac app keeps its own model (`ImpPreferences`) and maps it to the files in `ImpKit/Config`
(`SharedMapping`), through the core (`engine/ffi/src/config.rs`): it never parses the files itself.

| In the app | In the files |
| --- | --- |
| A service (name, address, model) | `providers.<id>`: `name`, `options.baseURL`, `defaultModel`, `models`. The id is a slug of the name |
| The default Brain | `model` (`provider/model#variant`; a variant the file has is kept) |
| An Imp's own Brain | the agent's `model`; "no Brain" is `imps.<name>.noBrain` |
| An Imp (name, About, personality, colour) | the agent file (`description`, body, `color`); the file name is the name |
| Size, favourite colour, character, memory, own animations, instructions, id | `imps.<name>` |
| Tool switches, shell, tool servers per Imp, single tools | the agent's `permissions`: the fewest rules that make the switches true (`deny` for off, an `allow` only to undo an outer `deny`) |
| Tool servers | `mcp.<name>` (`local` or `remote`, `disabled`) |
| Triggers, the animation library, requests, talk, the Hop address and device tool limits | `triggers`, `animations`, `requests`, `talk`, `link.hop`, `link.deviceTools` |
| A key typed in a service | `auth.json`; the lookup reports a provider as keyed when `options.apiKey` is set too |
| A tool server's sign-in | `auth.json`, under the server's name |
| Window, bubble, appearance, which Imps are out, where each stands, favourites noticed | `UserDefaults`, by the Imp's id |

How it behaves:

- Saving works out what differs from what was last read and writes only that, as merge patches the core applies
  after reading the files again under its lock. An agent file that did not change is not touched, a section
  the app holds unchanged is left as written (a default never removes what a file spells out), and what the
  app has no field for (`steps`, `request`, headers, variants, references such as `{env:NAME}`) stays.
- The colour of an Imp stays as the file has it until its hue is changed in the app.
- Renaming an Imp renames its file and moves its `imps` entry; removing one deletes both. The Imp keeps its
  id (`imps.<name>.id`; an agent without one gets a stable id made from its name).
- A change made outside is noticed within about two seconds. What was edited in the app and not yet written is
  written first, then the files are read again, so neither side loses an edit.
- Settings → Backup shows the config folder; Factory Reset removes the app's own data and offers, as a separate
  choice, to remove the shared configuration (used by the terminal app too). An Imp's Personality page opens
  its agent file in an editor or shows it in the Finder, and its Tools page lists the skills and commands of
  `~/.agents`, read only.

Deviations from the sections above:

- Providers come in the order of their ids (a JSON object has no order), and the app's services have no ids of
  their own: they are made from the provider's name.
- An Imp's switches show a group with an `ask` rule as on; every call is still decided by the rules, so an
  `ask` call waits in the bubble's prompt.
- The Mac app does not watch the files: it compares the stamp every two seconds.
- Project folders are not read by the Mac app, as above.
