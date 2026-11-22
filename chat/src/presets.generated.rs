// generated from spec/presets, do not edit. Run: node design/generate.mjs
#![cfg_attr(rustfmt, rustfmt::skip)]

/// A service offered on the first run: its address is filled in, and the person can change it.
pub struct Service {
    pub id: &'static str,
    /// It runs on this computer: no key is needed.
    pub local: bool,
    pub base_url: &'static str,
    /// Where to go to get a key, or a model to download.
    pub link: &'static str,
}

/// Remote, then local, as spec/presets/services.json lists them.
pub static SERVICES: &[Service] = &[
    Service { id: "remote", local: false, base_url: "https://openrouter.ai/api/v1", link: "https://openrouter.ai/workspaces/default/keys" },
    Service { id: "local", local: true, base_url: "http://localhost:11434/v1", link: "https://ollama.com/library/qwen3.8" },
];
