//! `{env:NAME}` and `{file:path}`, filled in anywhere a string is allowed in `imp.json` and in agent
//! front matter. The reading is behind [`Sources`], so the rules are pure.

use serde_json::Value;
use std::path::{Path, PathBuf};

/// Where values come from.
pub trait Sources {
    fn var(&self, name: &str) -> Option<String>;
    fn read(&self, path: &Path) -> std::io::Result<String>;
    fn home(&self) -> Option<&Path>;
}

/// Fills in the references in `text`. A path is `~/...` (the home folder), absolute, or relative to
/// `base` (the folder of the file that holds the reference). A missing variable, or a file that cannot
/// be read, is replaced by nothing and says why in `problems`. What was filled in is not read again, and
/// text that is not a reference stays as it is.
pub fn substitute(
    text: &str,
    base: &Path,
    sources: &dyn Sources,
    problems: &mut Vec<String>,
) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let reference = after.find('}').and_then(|end| {
            let inner = &after[..end];
            inner
                .strip_prefix("env:")
                .map(|n| (true, n))
                .or_else(|| inner.strip_prefix("file:").map(|p| (false, p)))
                .map(|(is_env, arg)| (is_env, arg, end))
        });
        match reference {
            Some((true, name, end)) if crate::agents::valid_env_name(name) => {
                match sources.var(name) {
                    Some(value) => out.push_str(&value),
                    None => problems.push(format!("the environment variable {name} is not set")),
                }
                rest = &after[end + 1..];
            }
            Some((false, path, end)) if !path.trim().is_empty() => {
                let full = resolve(path.trim(), base, sources.home());
                match sources.read(&full) {
                    Ok(content) => out.push_str(content.trim()),
                    Err(e) => problems.push(format!("could not read {}: {e}", full.display())),
                }
                rest = &after[end + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Fills in every string (not the keys) of a JSON value.
pub fn substitute_value(
    value: &mut Value,
    base: &Path,
    sources: &dyn Sources,
    problems: &mut Vec<String>,
) {
    match value {
        Value::String(s) => {
            if s.contains('{') {
                *s = substitute(s, base, sources, problems);
            }
        }
        Value::Array(items) => {
            for v in items {
                substitute_value(v, base, sources, problems);
            }
        }
        Value::Object(map) => {
            for (_, v) in map.iter_mut() {
                substitute_value(v, base, sources, problems);
            }
        }
        _ => {}
    }
}

/// `~`, `~/x`, an absolute path, or one relative to `base`.
pub fn resolve(path: &str, base: &Path, home: Option<&Path>) -> PathBuf {
    if let Some(home) = home {
        if path == "~" {
            return home.to_path_buf();
        }
        if let Some(rest) = path.strip_prefix("~/") {
            return home.join(rest);
        }
    }
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Env;
    use serde_json::json;

    fn run(text: &str, env: &Env, base: &Path) -> (String, Vec<String>) {
        let mut problems = Vec::new();
        (substitute(text, base, env, &mut problems), problems)
    }

    #[test]
    fn env_variables() {
        let env = Env::new(&[("KEY", "abc"), ("EMPTY", "")], None);
        let base = Path::new("/b");
        assert_eq!(
            run("Bearer {env:KEY}!", &env, base),
            ("Bearer abc!".into(), vec![])
        );
        assert_eq!(run("{env:KEY}{env:KEY}", &env, base).0, "abcabc");
        let (out, problems) = run("a{env:NOPE}b", &env, base);
        assert_eq!(out, "ab");
        assert_eq!(problems, ["the environment variable NOPE is not set"]);
        // A variable that is set but empty is empty, and not a problem.
        assert_eq!(run("[{env:EMPTY}]", &env, base), ("[]".into(), vec![]));
    }

    #[test]
    fn other_braces_stay() {
        let env = Env::new(&[("A", "x")], None);
        let base = Path::new("/b");
        for text in [
            "{}",
            "{ \"a\": 1 }",
            "{env:bad name}",
            "{env:}",
            "{file:}",
            "{unclosed",
            "{{env:A}",
            "$HOME ${A}",
        ] {
            let want = text.replace("{env:A}", "x");
            assert_eq!(run(text, &env, base).0, want, "{text}");
        }
    }

    #[test]
    fn files_are_read_from_the_right_place() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let base = dir.path().join("cfg");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(base.join("sub")).unwrap();
        std::fs::write(home.join("key"), "from-home\n").unwrap();
        std::fs::write(base.join("sub/key"), "  relative \n\n").unwrap();
        let abs = dir.path().join("abs");
        std::fs::write(&abs, "absolute").unwrap();
        let env = Env::new(&[], Some(&home));
        assert_eq!(run("{file:~/key}", &env, &base).0, "from-home");
        assert_eq!(run("k={file:sub/key}", &env, &base).0, "k=relative");
        assert_eq!(
            run(&format!("{{file:{}}}", abs.display()), &env, &base).0,
            "absolute"
        );
        let (out, problems) = run("x{file:missing}y", &env, &base);
        assert_eq!(out, "xy");
        assert!(problems[0].contains("could not read") && problems[0].contains("missing"));
    }

    #[test]
    fn values_are_filled_in_but_not_keys() {
        let env = Env::new(&[("V", "1")], None);
        let mut value = json!({"{env:V}": "{env:V}", "list": ["a{env:V}", 3, {"n": "{env:V}"}]});
        let mut problems = Vec::new();
        substitute_value(&mut value, Path::new("/"), &env, &mut problems);
        assert_eq!(
            value,
            json!({"{env:V}": "1", "list": ["a1", 3, {"n": "1"}]})
        );
        assert!(problems.is_empty());
    }

    #[test]
    fn what_is_filled_in_is_not_read_again() {
        let env = Env::new(&[("A", "{env:B}"), ("B", "no")], None);
        assert_eq!(run("{env:A}", &env, Path::new("/")).0, "{env:B}");
    }
}
