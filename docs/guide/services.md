# Services: bring any model

Imp works with any **OpenAI-compatible** service. Each service is an address (its `/v1` base URL) plus a model
and, if it needs one, a key.

## Two presets

When you add a service, Imp offers two presets. Each one fills in the address. You can change it to any
OpenAI-compatible service.

| Preset     | Address                        | Runs                                   | Notes                                |
| ---------- | ------------------------------ | -------------------------------------- | ------------------------------------ |
| **Remote** | `https://openrouter.ai/api/v1` | In the cloud (OpenRouter)              | The default. Needs a key.            |
| **Local**  | `http://localhost:11434/v1`    | On your Mac (Ollama's default address) | No key needed. Keeps data on device. |

The little ↗ next to a preset opens the page where you get a key (OpenRouter) or a model (Ollama).

## Other services

Any other OpenAI-compatible server works: enter its `/v1` address in the same form. For example, a local
[LM Studio](https://lmstudio.ai) server is usually `http://localhost:1234/v1`. Imp doesn't ship with an
address for it, so type the one your server shows.

## How services and models work together

- **Pick the model once**, when you add the service. Every Imp on that service uses it.
- **The starred service** is the one new Imps start with. Imp stars the first service you add. Click the star
  on another service to change it.
- **An Imp can choose its own** service or model, so a local model can handle private work while another Imp
  uses a larger cloud model.
- **Removing the starred service** makes the first remaining service the starred one. The model picked for
  the removed service is cleared too, because it belonged to that service.
- **With no service left**, Imps sleep until you add one.

## Keys

API keys are stored in a private file that only your user account can read. To store them in the Keychain
instead, turn on the Keychain option in **Settings › Brains**. See [Privacy](/guide/privacy).
