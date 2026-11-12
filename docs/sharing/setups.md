# Sharing setups as kits

A **kit** is Imps, triggers, borrowed tools and animations in one piece of JSON. A setup can be sent to a friend
instead of described. The file format is in the [Kit format reference](/sharing/kits).

## Importing

In Settings:

- **Import kit…** (on the Triggers and Tools tabs), and
- **Import…** (All Imps › App)

take any of these: pasted JSON, a web address, an `imp://add` link, or a dropped `.json` file.

## Exporting

- **Share as Kit** on a trigger copies its JSON to the clipboard, and the same goes for a tool.
- Each Imp's share sheet copies the kit or a link for that Imp.
- Animations can be shared too, from their own share button (or in the editor).

When the kit is short enough, Imp copies an `imp://add?kit=…` link instead of the JSON.

## An example kit

```json
{ "app": "1.7.0", "name": "Morning helper", "about": "optional text",
  "imps": [
    { "name": "Pip", "hue": 0.57, "favoriteHue": 0.9, "scale": 1.0,
      "personality": "A dry-witted morning companion.",
      "brain": { "model": "gpt-4o", "service": { "name": "OpenAI", "baseURL": "https://api.openai.com/v1" } },
      "shell": true,
      "tools": { "body": true, "senses": true, "setup": false, "troupe": true, "computer": false },
      "exchangesSent": 20, "sendsToolCalls": true,
      "mcpServers": ["Notes"],
      "triggers": [ { "name": "Good morning", "when": { "kind": "start" }, "prompt": "Greet me." } ] }
  ],
  "triggers": [
    { "name": "Plan my day", "when": { "kind": "wake" }, "only_if": [{ "kind": "hours", "text": "06:00-11:00" }],
      "prompt": "Look at my calendar and give me a short plan." }
  ],
  "mcpServers": {
    "Memory": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"] },
    "Notes":  { "url": "https://mcp.example.com/mcp", "headers": { "Authorization": "" } }
  } }
```

Animations and an Imp's `traits` are described, with every field and range, in the
[Kit format reference](/sharing/kits#animations-and-traits). A trigger has the same shape as the arguments of the
Imp's `imp_add_trigger` tool, and `mcpServers` uses the shape Claude Desktop and Cursor use. A plain MCP snippet, or a
single trigger (or a list of them), also works as a kit.

## What a kit contains

**Imps.** An Imp in a kit (with its character and its own animations) is written field by field, not as Imp stores
it. The file format therefore doesn't change when Imp's insides do.

- Only `name` is required. A missing field takes the default a new Imp has, and unknown fields are ignored.
- An Imp's model is named by its model and its service's address, never by a local id or key.
- Its `mcpServers` are names from the kit's own `mcpServers`.
- `chats` (optional: title, dates, turns and what the Imp remembers) are only written when you tick **Include chats**.
- Chats between Imps and pictures aren't exported.
- A single chat saved from Brain › Memory › Chats is the same chat object inside
  `{"app": "1.7.0", "imp": "Pip", "chat": {…}}`.

**Sharing an Imp.** Its share sheet copies the kit or a link (when it's short enough, and never with chats).
**Export…** saves a `.json` file, with an *Include chats* tick in the save panel. **Export all Imps** (All Imps › App)
saves every Imp with its triggers and tools, including the triggers every Imp shares. **Import…** is the way back, on
this Mac or another.

## Importing is always reviewed

- **Importing an Imp** shows it as a card (look, personality, model, tools, triggers, borrowed tools, chats) with a tick.
- It always arrives as a **new Imp**, at home and not out on your desktop, with a new name if the name is taken
  ("Pip 2").
- Its triggers are its own, and its tools are switched on for it. A tool you already have is reused.
- Its model is matched to a service you've added by address. If you haven't added it, Imp says so, and the Imp uses your
  default model until you choose one. **A service is never added for you.**
- A warning appears when computer control is on.
- Chats are put in its chat list.

**Nothing is added without your say.** Whatever the kit came from (a file, a web address or a link), Imp shows it first:

- each Imp, trigger and tool with what it says, and a tick on each,
- who the loose triggers and tools are for (one Imp or every Imp),
- warnings.

A tool that runs a command says so plainly, since that code runs on your Mac with your permissions. An Imp's personality
and triggers steer what it does with its tools, so read them. **Only add kits from people you trust.**

## Secrets are never exported

Environment variables and header values are blanked, as is anything after a `?` in a tool's or a service's address. A
shared kit has the names to fill in, but no keys. API keys of services are not in a kit at all. After adding a tool that
needs keys, Imp opens its form. Command arguments are exported as they are, so **don't put a key in one**.

## Limits

- Web addresses must be `https` (`http` only for `localhost`), answer within 10 seconds and be under 512 KB, the same as
  pasted text and links.
- A kit file on your Mac may be up to 20 MB, for chats.
- At most **20 Imps**, **100 chats per Imp**, **50 triggers**, **20 tools** and **50 animations**.

## Compatibility

Imp reads a kit by the keys it has, so a kit has no format number. Adding a field is safe: older Imps ignore keys they don't
know and give a missing one its default. A change an older Imp would misread uses new key names instead. `"app"` is the
version of Imp that wrote the file, for information only.

## Ready-made kits

Borrow ready-made kits from [The Den](/sharing/den). The fields for animations and an Imp's character are in the
[Kit format reference](/sharing/kits).
