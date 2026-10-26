# Imp

<p align="center"><img src="docs/screenshot.png" width="760" alt="Imp, a tiny red desk imp, floating above your windows"></p>

<p align="center">
  <b>A tiny desk imp for your Mac that does what you ask.</b><br>
  Private by design · Works fully offline · Bring any model
</p>

---

## Install

```sh
brew install --cask impsland/tap/imp
```

<p align="center">
  <a href="https://github.com/impsland/imp/releases/latest/download/Imp.dmg"><img src="https://img.shields.io/github/v/release/impsland/imp?label=Download%20Imp&style=for-the-badge&logo=apple&color=c0392b" alt="Download Imp for macOS"></a>
</p>

Or download **[Imp.dmg](https://github.com/impsland/imp/releases/latest/download/Imp.dmg)**, open it and drag Imp into
Applications. macOS 14 Sonoma or later, Apple silicon or Intel. Update with `brew upgrade --cask imp`.

<details>
  <summary>macOS says Imp can't be opened?</summary>

Imp isn't notarized by Apple yet. Homebrew takes care of this for you. For a manual download, run:

```sh
xattr -r -d com.apple.quarantine /Applications/Imp.app
```

or allow it in System Settings:

<p align="center"><img src="docs/how-to-open-an-unsigned-app-on-macos.svg" width="760" alt="Open an unsigned app on macOS"></p>
</details>

## Meet Imp

Imp is a soft red mochi head with two curled horns and two white eyes. It floats above your windows,
watches your cursor, and shows how it feels with the shape of its head and eyes. Click it, type or
talk to it, and it answers.

It has one tool: a **shell** on your Mac. Ask it to open an app, rename a pile of files, read a
document or call a web API, and it works out the commands itself.

## Private and offline

Imp has no account, no cloud and no telemetry. It talks **only** to the model service you pick.
If that's a model running on your own Mac, nothing leaves your Mac at all.

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

| What                | Where it stays                                                         |
| ------------------- | ---------------------------------------------------------------------- |
| API keys            | macOS Keychain                                                         |
| Chats and settings  | Your Mac (`~/Library/Application Support/Imp`)                         |
| Voice               | Apple speech recognition, on device whenever your Mac supports it      |
| Your requests       | Only the model service you added (local or remote, your choice)        |

## Bring any model

Imp works with any **OpenAI-compatible** service. Nothing is built in: you add the ones you want.

| Service      | Runs           | Address                         |
| ------------ | -------------- | ------------------------------- |
| Ollama       | On your Mac    | `http://localhost:11434/v1`     |
| LM Studio    | On your Mac    | `http://localhost:1234/v1`      |
| OpenRouter   | In the cloud   | `https://openrouter.ai/api/v1`  |
| OpenAI       | In the cloud   | `https://api.openai.com/v1`     |
| Anything else that speaks the OpenAI API | Anywhere | Its `/v1` address |

Each Imp can think with its own model, so a local one can handle private work while another uses
a bigger cloud model.

## What it can do

- **Talk, type or click.** Ask out loud or type. Answers show up in a speech bubble.
- **Use your Mac.** Imp runs shell commands and AppleScript to get things done for you.
- **Shortcuts.** Copy text anywhere, press your keys, and Imp translates, fixes or explains it on the spot.
- **More tools with MCP.** Connect Model Context Protocol servers, local or on the web.
- **A whole troupe.** Several Imps, each with its own name, colour, personality and model.
- **Automation.** `imp://` links for Shortcuts, Raycast and scripts:

  | Link                                   | Does                         |
  | -------------------------------------- | ---------------------------- |
  | `imp://ask?text=…&imp=Pip`             | Asks an Imp something        |
  | `imp://run?action=Translate%20clipboard` | Runs one of your shortcuts |
  | `imp://talk`                           | Starts listening             |
  | `imp://type?text=…`                    | Opens the text field         |
  | `imp://settings`                       | Opens Imp's window           |

<p align="center"><img src="docs/moods.png" width="760" alt="Imp's moods"></p>

## Get started with a local model

```sh
brew install ollama
ollama pull qwen3:8b
ollama serve
```

1. Open Imp from the menu bar and go to its window.
2. Add a service: pick **Ollama**.
3. Choose `qwen3:8b` as the model.
4. Click your Imp and say hello.

> [!NOTE]
> Imp runs the commands it writes without asking first, starting in its own workspace folder and
> with a time limit. You can switch the shell off for any Imp, and macOS still asks before Imp may
> use the microphone or control other apps.

## Build from source

```sh
make install   # builds Imp.app and copies it to /Applications
```
