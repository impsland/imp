# Privacy

Imp has **no telemetry**. Its model requests go **only** to the model service you pick.
If that service is a model running on your own Mac, nothing leaves your Mac at all.
Features you turn on, such as [Imp Link](/connecting/link), [The Den](/sharing/den) or an MCP server,
send data to the servers they use, as described below.

```
  ┌──────────────── your Mac ────────────────┐
  │                                          │
  │   You ──▶  Imp  ──▶  Ollama / LM Studio  │      no account
  │             │        (e.g. qwen3:8b)     │      no telemetry
  │             ▼                            │      no third-party servers
  │           shell                          │
  │                                          │
  └──────────────────────────────────────────┘
```

## Where your data stays

| What                | Where it stays                                                         |
| ------------------- | ---------------------------------------------------------------------- |
| API keys            | A private file only you can read, or the Keychain if you ask           |
| Chats and settings  | Your Mac (`~/Library/Application Support/Imp`)                         |
| Voice               | Apple speech recognition, on device whenever your Mac supports it      |
| Your requests       | Only the model service you added (local or remote, your choice)        |
| Device links        | Only devices you linked, encrypted end to end (off until you link one) |

## Read more

- How devices link and what the server can see: [Imp Link](/connecting/link) and the
  [threat model](/architecture/threat-model).
- What a shared kit leaves out: [Sharing setups](/sharing/setups#secrets-are-never-exported).
