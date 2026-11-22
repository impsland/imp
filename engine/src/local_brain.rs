//! Finding a model server on a computer, for the first run. This is the pure part: which servers to
//! look for and in what order (their model lists read with `chat::parse_model_ids`). The requests
//! themselves are made by the apps.

/// A model server that usually runs on a computer, and where it listens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalCandidate {
    pub name: &'static str,
    pub port: u16,
}

/// The servers to look for, in the order to offer them: Ollama, LM Studio, then llama.cpp.
pub const CANDIDATES: [LocalCandidate; 3] = [
    LocalCandidate {
        name: "Ollama",
        port: 11434,
    },
    LocalCandidate {
        name: "LM Studio",
        port: 1234,
    },
    LocalCandidate {
        name: "llama.cpp",
        port: 8080,
    },
];

impl LocalCandidate {
    /// The base URL of the server on `host` (an OpenAI-compatible address, with `/v1`).
    pub fn base_url(&self, host: &str) -> String {
        format!("http://{host}:{}/v1", self.port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_candidates_come_in_the_order_to_offer_them() {
        let names: Vec<_> = CANDIDATES.iter().map(|c| c.name).collect();
        assert_eq!(names, ["Ollama", "LM Studio", "llama.cpp"]);
        let ports: Vec<_> = CANDIDATES.iter().map(|c| c.port).collect();
        assert_eq!(ports, [11434, 1234, 8080]);
        assert_eq!(
            CANDIDATES[0].base_url("localhost"),
            "http://localhost:11434/v1"
        );
    }
}
