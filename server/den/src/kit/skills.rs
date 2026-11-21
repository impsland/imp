//! Skills of a kit: references for `npx skills add <source>`. The Den never stores skill files.

use std::collections::HashSet;

use serde_json::Value;

use super::Problems;

pub(super) const MAX_SKILLS: usize = 20;
const MAX_NAME: usize = 64;
const MAX_SOURCE: usize = 200;

/// `a-z`, `0-9` and inner dashes.
fn dashed_words(s: &str) -> bool {
    !s.is_empty()
        && s.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// Letters, digits and the few marks that are safe in a shell word and in a path.
fn plain(s: &str, extra: &[u8]) -> bool {
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
}

/// What is wrong with the `source` of a skill, if anything.
pub fn source_problem(source: &str) -> Option<&'static str> {
    if source.is_empty() || source.len() > MAX_SOURCE {
        return Some("must have 1 to 200 characters");
    }
    if let Some(rest) = source.strip_prefix("https://") {
        let host = rest.split('/').next().unwrap_or_default();
        if host.is_empty() || !plain(rest, b"._-/:%+=,~") {
            return Some("an https:// address with no spaces, quotes or shell characters");
        }
        return None;
    }
    let parts: Vec<&str> = source.split('/').collect();
    let ok = (2..=8).contains(&parts.len())
        && parts
            .iter()
            .all(|p| !p.is_empty() && *p != "." && *p != ".." && plain(p, b"._-"));
    if ok {
        None
    } else {
        Some("must be owner/repo, owner/repo/path or an https:// address")
    }
}

/// Checks the `skills` list of a kit, adding a problem for each bad entry.
pub(super) fn check_skills(skills: &[Value], problems: &mut Problems) {
    let mut seen = HashSet::new();
    for (i, skill) in skills.iter().enumerate() {
        let at = format!("/skills/{i}");
        let Some(skill) = skill.as_object() else {
            problems.add(&at, "must be an object with a name and a source");
            continue;
        };
        match skill.get("name").and_then(Value::as_str) {
            Some(n) if n.len() <= MAX_NAME && dashed_words(n) => {
                if !seen.insert(n) {
                    problems.add(&format!("{at}/name"), "the same skill twice");
                }
            }
            _ => problems.add(
                &format!("{at}/name"),
                "1 to 64 characters of a-z, 0-9 and inner dashes",
            ),
        }
        match skill.get("source").and_then(Value::as_str) {
            Some(s) => {
                if let Some(problem) = source_problem(s) {
                    problems.add(&format!("{at}/source"), problem);
                }
            }
            None => problems.add(&format!("{at}/source"), "must be text"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources() {
        for ok in [
            "anthropics/skills",
            "anthropics/skills/skills/pdf",
            "https://github.com/anthropics/skills/tree/main/skills/pdf",
        ] {
            assert!(source_problem(ok).is_none(), "{ok}");
        }
        for bad in [
            "",
            "pdf",
            "a/b c",
            "a/b;rm -rf",
            "a/b/../c",
            "http://x.y/z",
            "https://",
            "https://x.y/a'b",
            "a/b$(x)",
            "a//b",
        ] {
            assert!(source_problem(bad).is_some(), "{bad}");
        }
        assert!(source_problem(&format!("a/{}", "b".repeat(200))).is_some());
    }
}
