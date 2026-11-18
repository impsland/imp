// generated from spec/presets, do not edit. Run: node design/generate.mjs

/// The presets as their JSON files. Compiled in, so no resource bundle has to be found at run time.
enum Presets {
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
