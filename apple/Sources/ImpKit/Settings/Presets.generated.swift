// generated from spec/presets, do not edit. Run: node design/generate.mjs

/// The presets as their JSON files. Compiled in, so no resource bundle has to be found at run time.
enum Presets {
    /// spec/presets/starter-kit.json: a kit, read by `Kit.parse` like any other.
    static let starterKitJSON = #"""
{
  "name": "Starter kit",
  "about": "The triggers Imp offers on a fresh install: one click opens the text box, two clicks open the settings, a quiet while puts the Imp to sleep and the cursor coming close wakes it. Every Imp shares them. Change, switch off or delete any of them; Add the starter kit in Triggers brings them back.",
  "triggers": [
    { "name": "Type", "when": { "kind": "clicks", "number": 1 }, "do": "type", "with_clipboard": false },
    { "name": "Settings", "when": { "kind": "clicks", "number": 2 }, "do": "settings", "with_clipboard": false },
    { "name": "Fall asleep", "when": { "kind": "idle", "number": 240 }, "do": "sleep", "animation": "sleep", "with_clipboard": false },
    { "name": "Wake up", "when": { "kind": "enter" }, "do": "wakeUp", "with_clipboard": false }
  ]
}
"""#

    /// spec/presets/services.json: the services offered when adding one.
    static let servicesJSON = #"""
{
  "about": "The two ways to give an Imp a Brain, offered when adding a service and on the first run. Remote is the default. Each pre-fills its address, which the person can change to any OpenAI-compatible service.",
  "default": "remote",
  "services": [
    {
      "id": "remote",
      "local": false,
      "symbol": "cloud.fill",
      "baseURL": "https://openrouter.ai/api/v1",
      "link": "https://openrouter.ai/workspaces/default/keys"
    },
    {
      "id": "local",
      "local": true,
      "symbol": "desktopcomputer",
      "baseURL": "http://localhost:11434/v1",
      "link": "https://ollama.com/library/qwen3.8"
    }
  ]
}
"""#
}
