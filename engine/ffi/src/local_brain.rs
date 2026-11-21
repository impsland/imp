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
