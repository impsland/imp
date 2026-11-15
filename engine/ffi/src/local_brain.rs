//! Finding a model server on a computer: the candidates and the readers. The rules stay in `imp-engine`.

use imp_engine::local_brain;

/// A model server that usually runs on a computer.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LocalCandidate {
    pub name: String,
    pub port: u16,
}

/// The servers to look for, in the order to offer them.
#[uniffi::export]
pub fn local_brain_candidates() -> Vec<LocalCandidate> {
    local_brain::CANDIDATES
        .iter()
        .map(|c| LocalCandidate {
            name: c.name.to_owned(),
            port: c.port,
        })
        .collect()
}

/// The model names in the answer to `GET /models`.
#[uniffi::export]
pub fn local_brain_parse_models(body: String) -> Vec<String> {
    local_brain::parse_models(&body)
}

/// What checking a typed server address gave: the base URL, or a sentence that says why not.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerBaseUrl {
    pub url: String,
    pub message: Option<String>,
}

/// The base URL for what a person typed for a server on their network.
#[uniffi::export]
pub fn local_brain_server_url(text: String) -> ServerBaseUrl {
    match local_brain::server_base_url(&text) {
        Ok(url) => ServerBaseUrl { url, message: None },
        Err(e) => ServerBaseUrl {
            url: String::new(),
            message: Some(e.to_string()),
        },
    }
}
