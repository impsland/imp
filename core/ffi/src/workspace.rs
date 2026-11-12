//! Workspace file references: the rules. The apps keep only the file reading and writing.

use imp_core::workspace;
use std::sync::Mutex;

/// A file in an Imp's Workspace that can be named from anywhere.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WorkspaceRef {
    pub owner: String,
    pub path: String,
    pub size: Option<u64>,
    pub sha256: Option<String>,
    pub media_type: Option<String>,
    pub fragment: Option<String>,
}

impl From<workspace::WorkspaceReference> for WorkspaceRef {
    fn from(r: workspace::WorkspaceReference) -> Self {
        Self {
            owner: r.owner,
            path: r.path,
            size: r.size,
            sha256: r.sha256,
            media_type: r.media_type,
            fragment: r.fragment,
        }
    }
}

impl From<WorkspaceRef> for workspace::WorkspaceReference {
    fn from(r: WorkspaceRef) -> Self {
        Self {
            owner: r.owner,
            path: r.path,
            size: r.size,
            sha256: r.sha256,
            media_type: r.media_type,
            fragment: r.fragment,
        }
    }
}

/// Files up to this size get a checksum when a reference is made.
#[uniffi::export]
pub fn workspace_checksum_limit() -> u64 {
    workspace::CHECKSUM_LIMIT
}

/// Whether `text` is written as a file reference (valid or not).
#[uniffi::export]
pub fn workspace_is_reference(text: String) -> bool {
    workspace::WorkspaceReference::is_reference(&text)
}

/// Reads a reference. Nothing is looked up.
#[uniffi::export]
pub fn workspace_parse(text: String) -> Option<WorkspaceRef> {
    workspace::WorkspaceReference::parse(&text).map(Into::into)
}

/// The reference as text.
#[uniffi::export]
pub fn workspace_text(reference: WorkspaceRef) -> String {
    workspace::WorkspaceReference::from(reference).to_text()
}

/// A path as a reference carries it, or nothing if it is not allowed.
#[uniffi::export]
pub fn workspace_normalize(path: String) -> Option<String> {
    workspace::normalize(&path)
}

/// The path inside `root` that a plain reference means, or nothing if it points outside.
#[uniffi::export]
pub fn workspace_relative_path(reference: String, root: String) -> Option<String> {
    workspace::relative_path(&reference, &root)
}

/// Lowercase hex SHA-256 of some bytes.
#[uniffi::export]
pub fn workspace_checksum(data: Vec<u8>) -> String {
    workspace::checksum(&data)
}

/// A SHA-256 taken in pieces.
#[derive(uniffi::Object)]
pub struct WorkspaceHasher(Mutex<Option<workspace::Hasher>>);

#[uniffi::export]
impl WorkspaceHasher {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self(Mutex::new(Some(workspace::Hasher::new())))
    }

    pub fn update(&self, data: Vec<u8>) {
        if let Some(h) = self.0.lock().expect("hasher lock").as_mut() {
            h.update(&data);
        }
    }

    /// The checksum as lowercase hex. Empty if already finished.
    pub fn finish(&self) -> String {
        self.0
            .lock()
            .expect("hasher lock")
            .take()
            .map(workspace::Hasher::finish)
            .unwrap_or_default()
    }
}

impl Default for WorkspaceHasher {
    fn default() -> Self {
        Self::new()
    }
}
