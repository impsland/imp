//! Which projects the person allowed. A project's `.agents/imp.json` can start programs and send keys,
//! so it waits until the person trusts the project as it is now: the store keeps the digest of what was
//! allowed, and a change gives another digest, which waits again.

use crate::config::store::{ConfigError, write_atomic};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The folders the person allowed, each with the digest of what they allowed.
#[derive(Debug, Clone, Default)]
pub struct TrustStore {
    path: Option<PathBuf>,
}

impl TrustStore {
    /// The store in this file (the data folder's `trusted_folders.json`).
    pub fn at(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    /// No store: nothing is trusted and nothing can be.
    pub fn none() -> Self {
        Self::default()
    }

    fn read(&self) -> BTreeMap<String, String> {
        self.path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    fn key(root: &Path) -> String {
        root.canonicalize()
            .unwrap_or_else(|_| root.to_path_buf())
            .display()
            .to_string()
    }

    /// Whether the folder was allowed as it is now.
    pub fn allows(&self, root: &Path, digest: &str) -> bool {
        self.read().get(&Self::key(root)).map(String::as_str) == Some(digest)
    }

    /// Allows the folder as it is now (`Some`), or no longer (`None`).
    pub fn set(&self, root: &Path, digest: Option<&str>) -> Result<(), ConfigError> {
        let path = self.path.as_ref().ok_or(ConfigError::NoFolder)?;
        let mut all = self.read();
        match digest {
            Some(d) => all.insert(Self::key(root), d.to_string()),
            None => all.remove(&Self::key(root)),
        };
        let mut text = serde_json::to_string_pretty(&all).unwrap_or_default();
        text.push('\n');
        write_atomic(path, text.as_bytes(), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_is_per_folder_and_per_digest() {
        let dir = tempfile::tempdir().unwrap();
        let store = TrustStore::at(dir.path().join("data/trusted.json"));
        let project = dir.path().join("p");
        std::fs::create_dir(&project).unwrap();
        assert!(!store.allows(&project, "d1"));
        store.set(&project, Some("d1")).unwrap();
        assert!(store.allows(&project, "d1"));
        assert!(!store.allows(&project, "d2"));
        assert!(!store.allows(dir.path(), "d1"));
        store.set(&project, None).unwrap();
        assert!(!store.allows(&project, "d1"));
        assert!(matches!(
            TrustStore::none().set(&project, Some("d")),
            Err(ConfigError::NoFolder)
        ));
        assert!(!TrustStore::none().allows(&project, "d"));
    }
}
