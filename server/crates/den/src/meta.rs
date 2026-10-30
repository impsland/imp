//! The names and labels around a kit: handles, slugs, summaries and tags.

use crate::error::Violation;

const RESERVED: [&str; 8] = [
    "me", "admin", "root", "imp", "den", "hop", "system", "support",
];

fn dashed_words(s: &str) -> bool {
    !s.is_empty()
        && s.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

pub fn handle_problem(handle: &str) -> Option<&'static str> {
    if !(3..=32).contains(&handle.len()) {
        Some("must have 3 to 32 characters")
    } else if !dashed_words(handle) {
        Some("may only have lowercase letters, digits and inner dashes")
    } else if RESERVED.contains(&handle) {
        Some("is reserved")
    } else {
        None
    }
}

pub fn slug_problem(slug: &str) -> Option<&'static str> {
    if !(1..=48).contains(&slug.len()) {
        Some("must have 1 to 48 characters")
    } else if !dashed_words(slug) {
        Some("may only have lowercase letters, digits and inner dashes")
    } else {
        None
    }
}

pub fn tag_problem(tag: &str) -> Option<&'static str> {
    if (1..=24).contains(&tag.len())
        && tag
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        None
    } else {
        Some("must have 1 to 24 characters from a-z, 0-9 and dashes")
    }
}

/// Checks `summary` and `tags` of a published item.
pub fn label_problems(summary: &str, tags: &[String]) -> Vec<Violation> {
    let mut out = Vec::new();
    let mut add = |pointer: String, detail: &str| {
        out.push(Violation {
            pointer,
            detail: detail.to_owned(),
        })
    };
    if summary.trim().is_empty() || summary.chars().count() > 120 || summary.contains(['\n', '\r'])
    {
        add(
            "/summary".to_owned(),
            "must be one line of 1 to 120 characters",
        );
    }
    if !(1..=5).contains(&tags.len()) {
        add("/tags".to_owned(), "needs 1 to 5 tags");
    }
    for (i, tag) in tags.iter().enumerate() {
        if let Some(problem) = tag_problem(tag) {
            add(format!("/tags/{i}"), problem);
        }
    }
    let mut seen = std::collections::HashSet::new();
    if !tags.iter().all(|t| seen.insert(t)) {
        add("/tags".to_owned(), "has the same tag twice");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles() {
        assert!(handle_problem("pip-the-imp").is_none());
        assert!(handle_problem("ab").is_some());
        assert!(handle_problem("-ab").is_some());
        assert!(handle_problem("a--b").is_some());
        assert!(handle_problem("Abc").is_some());
        assert!(handle_problem("admin").is_some());
        assert!(handle_problem(&"a".repeat(33)).is_some());
    }

    #[test]
    fn slugs_and_tags() {
        assert!(slug_problem("moody-moves").is_none());
        assert!(slug_problem(&"a".repeat(49)).is_some());
        assert!(tag_problem("fun").is_none());
        assert!(tag_problem("Fun").is_some());
    }
}
