//! Finding a model server on a computer, for the first run. This is the pure part: which servers to
//! look for and in what order, and how to read the answer of one. The requests themselves are made
//! by the apps.

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

/// The model names in the answer to `GET /models`, sorted and without repeats. Anything that is not
/// a model list gives none.
pub fn parse_models(body: &str) -> Vec<String> {
    let Ok(json) = serde_json::from_str::<serde_json::Value>(body) else {
        return Vec::new();
    };
    let mut names: Vec<String> = json
        .get("data")
        .and_then(|d| d.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|m| m.get("id")?.as_str())
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.dedup();
    names
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

    #[test]
    fn models_are_read_sorted_and_once() {
        let body = r#"{"object":"list","data":[{"id":"qwen3"},{"id":"llama3"},{"id":"qwen3"},{"id":" "},{"x":1}]}"#;
        assert_eq!(parse_models(body), ["llama3", "qwen3"]);
    }

    #[test]
    fn what_is_not_a_model_list_gives_none() {
        for body in [
            "",
            "nope",
            "[]",
            r#"{"data":"x"}"#,
            r#"{"error":{"message":"no"}}"#,
        ] {
            assert!(parse_models(body).is_empty(), "{body:?}");
        }
    }
}
