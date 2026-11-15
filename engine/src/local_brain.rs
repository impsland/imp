//! Finding a model server on a computer, for the first run. This is the pure part: which servers to
//! look for and in what order, how to read the answer of one, and how to turn what a person typed
//! into a server address. The requests themselves are made by the apps.

use crate::link::hop::is_host;

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

/// Why a typed server address was refused. The text is what a person reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ServerAddressError {
    #[error("Type the address of the computer, like 192.168.1.20 or my-mac.local.")]
    Empty,
    #[error("That is not a valid address. Use a name or numbers, like 192.168.1.20.")]
    Host,
    #[error("The port must be a number from 1 to 65535.")]
    Port,
    #[error("The address must start with http:// or https://.")]
    Scheme,
}

/// What a person typed for a server on their network, as the base URL to use. `192.168.1.20` becomes
/// `http://192.168.1.20:11434/v1` (the first server's port, and `/v1`). A full URL keeps its scheme,
/// port and path.
pub fn server_base_url(text: &str) -> Result<String, ServerAddressError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(ServerAddressError::Empty);
    }
    let (scheme, rest) = match text.split_once("://") {
        Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
        None => ("http".to_owned(), text),
    };
    if scheme != "http" && scheme != "https" {
        return Err(ServerAddressError::Scheme);
    }
    let (authority, path) = match rest.find('/') {
        Some(i) => rest.split_at(i),
        None => (rest, ""),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, digits)) => {
            let port = (!digits.is_empty()
                && digits.len() <= 5
                && digits.bytes().all(|b| b.is_ascii_digit()))
            .then(|| digits.parse::<u16>().ok().filter(|p| *p > 0))
            .flatten()
            .ok_or(ServerAddressError::Port)?;
            (host, Some(port))
        }
        None => (authority, None),
    };
    let host = host.to_ascii_lowercase();
    if !is_host(&host) {
        return Err(ServerAddressError::Host);
    }
    let port = port.or((scheme == "http").then_some(CANDIDATES[0].port));
    let path = path.trim_end_matches('/');
    let path = if path.is_empty() { "/v1" } else { path };
    Ok(match port {
        Some(port) => format!("{scheme}://{host}:{port}{path}"),
        None => format!("{scheme}://{host}{path}"),
    })
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

    #[test]
    fn a_typed_address_becomes_a_base_url() {
        let cases = [
            ("192.168.1.20", "http://192.168.1.20:11434/v1"),
            ("  My-Mac.local ", "http://my-mac.local:11434/v1"),
            ("192.168.1.20:1234", "http://192.168.1.20:1234/v1"),
            ("http://192.168.1.20:8080", "http://192.168.1.20:8080/v1"),
            ("http://192.168.1.20:8080/", "http://192.168.1.20:8080/v1"),
            (
                "https://models.example.com/api/v1/",
                "https://models.example.com/api/v1",
            ),
        ];
        for (typed, want) in cases {
            assert_eq!(server_base_url(typed).as_deref(), Ok(want), "{typed:?}");
        }
    }

    #[test]
    fn a_bad_address_says_why() {
        assert_eq!(server_base_url("  "), Err(ServerAddressError::Empty));
        assert_eq!(server_base_url("bad host!"), Err(ServerAddressError::Host));
        assert_eq!(
            server_base_url("a.local:99999"),
            Err(ServerAddressError::Port)
        );
        assert_eq!(server_base_url("a.local:"), Err(ServerAddressError::Port));
        assert_eq!(
            server_base_url("ftp://a.local"),
            Err(ServerAddressError::Scheme)
        );
    }
}
