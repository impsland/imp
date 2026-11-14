# The terminal app (`imp`)

Imp also has a command line version that works on any computer with a Rust toolchain. It makes Imps and chats
with them in a terminal, using any OpenAI-compatible service. Its Imps use tools from MCP servers, message
each other, and travel to your Mac and iPhone and back, as in the apps.

## Install

```sh
cargo install --path cli
```

## Use

```sh
export OPENROUTER_API_KEY=sk-or-...
imp imp new pip --model openai/gpt-6-luna --api-key-env OPENROUTER_API_KEY
imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem .   # the folder you chat in
imp chat
```

In the chat, type `/` for commands: `/model`, `/base_url` and `/api_key` change the brain, `/mcp add` adds
tools, `/imp` switches Imps. Tool calls (`⏺`) and messages to other Imps (`⇢`) show as one line each.

Your API key stays in an environment variable, the system keychain or the chat's memory, and is never written
to the settings file.

## With your devices

`imp qr` (or `/pair` in the chat) shows a code to scan with Imp on a Mac or an iPhone. While a chat or
`imp link` runs, this computer is online as one of your devices: `/send iPhone` sends an Imp there (it keeps
thinking on the computer), `/call` brings it back, and Imps thrown to the computer visit it and can be talked
to with `/imp NAME`. It follows [Imp Link](/connecting/link).

Run `imp --help` to see every command. The `imp` program can also run the Den and the Hop (`imp serve`). See
`server/README.md` in the repository.

Full details are in `cli/README.md`.
