//! Workspace file references and path rules. Follows Swift `WorkspaceReference`.
//!
//! The vectors are `Tests/Fixtures/workspace-refs.json`. Nothing here touches the disk except the
//! symlink check in [`relative_path`], which only runs for absolute paths.

use sha2::{Digest, Sha256};
use std::path::Path;

const SCHEME: &str = "imp-file";
const MAX_PATH_BYTES: usize = 1024;
const MAX_DEPTH: usize = 32;

/// A file in an Imp's Workspace that can be named from anywhere:
/// `imp-file://<owner-uuid>/<path>?size=<bytes>&sha256=<64 hex>&type=<mime>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceReference {
    /// Lowercase.
    pub owner: String,
    /// Relative to the owner's Workspace, `/`-separated, normalised.
    pub path: String,
    pub size: Option<u64>,
    pub sha256: Option<String>,
    pub media_type: Option<String>,
    pub fragment: Option<String>,
}

/// A relative, `/`-separated path with no `.`, empty or `..` parts, no backslash, NUL or control
/// characters, and a sane length. `None` for anything else (and for a path starting with `~`).
pub fn normalize(path: &str) -> Option<String> {
    if path.is_empty()
        || path.len() > MAX_PATH_BYTES
        || path.starts_with('/')
        || path.starts_with('~')
        || path
            .chars()
            .any(|c| (c as u32) < 0x20 || c as u32 == 0x7f || c == '\\')
    {
        return None;
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    if parts.is_empty() || parts.len() > MAX_DEPTH || parts.contains(&"..") {
        return None;
    }
    let kept: Vec<&str> = parts.into_iter().filter(|p| *p != ".").collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept.join("/"))
    }
}

/// An absolute path with `.`, `..` and doubled slashes taken out. `None` if `..` climbs above `/`.
fn lexical(path: &str) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/').filter(|p| !p.is_empty()) {
        match part {
            "." => {}
            ".." => {
                parts.pop()?;
            }
            p => parts.push(p),
        }
    }
    Some(format!("/{}", parts.join("/")))
}

fn relative_to(path: &str, base: &str) -> Option<String> {
    let prefix = if base == "/" {
        "/".to_string()
    } else {
        format!("{base}/")
    };
    path.strip_prefix(&prefix).map(str::to_string)
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(
                u8::from_str_radix(hex, 16)
                    .ok()
                    .filter(|_| hex.bytes().all(|b| b.is_ascii_hexdigit()))?,
            );
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn has_scheme(text: &str) -> Option<&str> {
    let (scheme, _) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c)))
        .then_some(scheme)
}

/// The path inside `root` that a plain reference (the way a reply writes one) means: relative to
/// `root`, absolute inside it, or a `file:` URL. `..` may be used as long as it stays inside.
/// `None` for web addresses, junk, and anything that points outside `root`, however it is spelled.
/// This is lexical, except that an absolute path is also tried with symlinks resolved.
pub fn relative_path(reference: &str, root: &str) -> Option<String> {
    let mut text = reference.trim().to_string();
    if text.is_empty() {
        return None;
    }
    if let Some(scheme) = has_scheme(&text) {
        if !scheme.eq_ignore_ascii_case("file") {
            return None;
        }
        let rest = &text[scheme.len() + 1..];
        let rest = rest.strip_prefix("//").unwrap_or(rest);
        // A file URL has an empty host, so the path starts at the next slash.
        let path = if reference.trim()[scheme.len() + 1..].starts_with("//") {
            &rest[rest.find('/')?..]
        } else {
            rest
        };
        text = path.split(['?', '#']).next()?.to_string();
    } else {
        text = text.split(['?', '#']).next()?.to_string();
    }
    text = percent_decode(&text).unwrap_or(text);
    if let Some(rest) = text.strip_prefix('~') {
        let home = std::env::var("HOME").ok()?;
        text = format!("{home}{rest}");
    }
    if text.is_empty() || text.contains('\0') {
        return None;
    }
    let base = lexical(root)?;
    if !text.starts_with('/') {
        let inside = lexical(&format!("{base}/{text}"))?;
        return normalize(&relative_to(&inside, &base)?);
    }
    if let Some(rel) = lexical(&text).and_then(|inside| relative_to(&inside, &base)) {
        return normalize(&rel);
    }
    let real = std::fs::canonicalize(Path::new(&text)).ok()?;
    let real_root = std::fs::canonicalize(Path::new(root)).ok()?;
    let rel = real.strip_prefix(real_root).ok()?;
    normalize(&rel.to_string_lossy())
}

fn is_uuid(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(g, n)| g.len() == n && g.bytes().all(|b| b.is_ascii_hexdigit()))
}

impl WorkspaceReference {
    /// Whether `text` is written in this form (valid or not).
    pub fn is_reference(text: &str) -> bool {
        text.trim()
            .to_ascii_lowercase()
            .starts_with(&format!("{SCHEME}:"))
    }

    /// Reads a reference. `None` unless it is well formed: the scheme, an owner id, a normalised
    /// path, and any size, checksum and type it gives being sane. Nothing is looked up.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if !Self::is_reference(text) {
            return None;
        }
        let rest = text[SCHEME.len() + 1..].strip_prefix("//")?;
        let (rest, fragment) = match rest.split_once('#') {
            Some((r, f)) => (r, Some(percent_decode(f)?)),
            None => (rest, None),
        };
        let (rest, query) = match rest.split_once('?') {
            Some((r, q)) => (r, Some(q)),
            None => (rest, None),
        };
        let slash = rest.find('/')?;
        let (host, raw_path) = rest.split_at(slash);
        if !is_uuid(host) {
            return None;
        }
        let decoded = percent_decode(&raw_path[1..])?;
        let path = normalize(&decoded).filter(|p| *p == decoded)?;
        let mut reference = Self {
            owner: host.to_ascii_lowercase(),
            path,
            size: None,
            sha256: None,
            media_type: None,
            fragment: fragment.filter(|f| !f.is_empty()),
        };
        let mut seen: Vec<&str> = Vec::new();
        for item in query.into_iter().flat_map(|q| q.split('&')) {
            let (name, value) = item.split_once('=')?;
            if seen.contains(&name) {
                return None;
            }
            seen.push(name);
            let value = percent_decode(value)?;
            match name {
                "size" => {
                    let n: u64 = value
                        .parse()
                        .ok()
                        .filter(|n: &u64| n.to_string() == value)?;
                    reference.size = Some(n);
                }
                "sha256" => {
                    let ok = value.len() == 64
                        && value
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
                    if !ok {
                        return None;
                    }
                    reference.sha256 = Some(value);
                }
                "type" => {
                    if value.is_empty()
                        || value.len() > 127
                        || !value.bytes().all(|b| b.is_ascii_graphic())
                    {
                        return None;
                    }
                    reference.media_type = Some(value);
                }
                _ => return None,
            }
        }
        Some(reference)
    }

    /// Where this file is, given the owner's Workspace folder.
    pub fn path_in(&self, root: &Path) -> std::path::PathBuf {
        self.path
            .split('/')
            .fold(root.to_path_buf(), |acc, part| acc.join(part))
    }
}

/// Lowercase hex SHA-256 of some bytes.
pub fn checksum(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../Tests/Fixtures/workspace-refs.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
    }

    #[test]
    fn normalize_matches_the_vectors() {
        let f = fixture();
        for case in f["normalize"].as_array().unwrap() {
            let got = normalize(case["input"].as_str().unwrap());
            assert_eq!(got.as_deref(), case["result"].as_str(), "{}", case["input"]);
        }
    }

    #[test]
    fn paths_match_the_vectors() {
        let f = fixture();
        let root = f["root"].as_str().unwrap();
        for case in f["paths"].as_array().unwrap() {
            let got = relative_path(case["input"].as_str().unwrap(), root);
            assert_eq!(got.as_deref(), case["result"].as_str(), "{}", case["name"]);
        }
    }

    #[test]
    fn refs_match_the_vectors() {
        let f = fixture();
        for case in f["refs"].as_array().unwrap() {
            let got = WorkspaceReference::parse(case["ref"].as_str().unwrap());
            if case.get("valid") == Some(&Value::Bool(false)) {
                assert!(got.is_none(), "{}", case["name"]);
                continue;
            }
            let got = got.unwrap_or_else(|| panic!("{} should parse", case["name"]));
            assert_eq!(
                got.owner,
                case["owner"].as_str().unwrap(),
                "{}",
                case["name"]
            );
            assert_eq!(got.path, case["path"].as_str().unwrap(), "{}", case["name"]);
            assert_eq!(got.size, case["size"].as_u64(), "{}", case["name"]);
            assert_eq!(
                got.sha256.as_deref(),
                case["sha256"].as_str(),
                "{}",
                case["name"]
            );
            assert_eq!(
                got.media_type.as_deref(),
                case["type"].as_str(),
                "{}",
                case["name"]
            );
        }
    }

    #[test]
    fn checksums_match_the_vectors() {
        let f = fixture();
        for case in f["checksums"].as_array().unwrap() {
            assert_eq!(
                checksum(case["text"].as_str().unwrap().as_bytes()),
                case["sha256"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn paths_join_under_the_root() {
        let r =
            WorkspaceReference::parse("imp-file://11111111-2222-3333-4444-555555555555/a/b.txt#x")
                .unwrap();
        assert_eq!(r.fragment.as_deref(), Some("x"));
        assert_eq!(r.path_in(Path::new("/w")), Path::new("/w/a/b.txt"));
    }
}
