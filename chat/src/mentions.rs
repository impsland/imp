//! Files picked with `@` in a message, such as `@notes/todo.md`. While a word that starts with `@` is
//! typed, the chat lists the folder's files that match it. When the message is sent, the text of each
//! file named that way goes with it, after the message, so the Imp can read it without a tool. The
//! chat shows only what was written and a line naming the files.

use crate::session::expand;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// What separates a message from the files that go with it.
pub const ATTACHED: &str = "\n\n<attached_files>";
const ATTACHED_END: &str = "</attached_files>";
/// The largest file attached.
const MOST_FILE: u64 = 100 * 1024;
/// The most text attached to one message, all files together.
const MOST_ALL: usize = 256 * 1024;
/// The most entries listed for a folder.
const MOST_ENTRIES: usize = 200;
/// The most paths offered while typing, and how long finding them may take.
const MOST_LISTED: usize = 20_000;
const LIST_TIME: Duration = Duration::from_millis(400);
/// Folders that are tools' output or downloads, never worth listing.
const SKIPPED: &[&str] = &[
    "node_modules",
    "target",
    "DerivedData",
    "__pycache__",
    "venv",
    "dist",
    "build",
    "Pods",
];
/// Hidden folders that people do mean to pick from.
const SHOWN_HIDDEN: &[&str] = &[".agents", ".github"];

/// The folder's files and folders (folders end with `/`), nearest first, as paths from `root`.
/// Hidden entries and build output are left out, and the walk stops after a moment in a huge folder.
pub fn list_files(root: &Path) -> Vec<String> {
    let started = Instant::now();
    let mut out = Vec::new();
    let mut queue = std::collections::VecDeque::from([PathBuf::new()]);
    while let Some(rel) = queue.pop_front() {
        let Ok(read) = std::fs::read_dir(root.join(&rel)) else {
            continue;
        };
        let mut entries: Vec<(String, bool)> = read
            .filter_map(|e| {
                let e = e.ok()?;
                let name = e.file_name().to_string_lossy().to_string();
                let dir = e.file_type().ok()?.is_dir();
                Some((name, dir))
            })
            .filter(|(name, dir)| {
                let hidden = name.starts_with('.') && !SHOWN_HIDDEN.contains(&name.as_str());
                !hidden && !(*dir && SKIPPED.contains(&name.as_str()))
            })
            .collect();
        entries.sort();
        for (name, dir) in entries {
            let path = rel.join(&name);
            let shown = path.to_string_lossy().replace('\\', "/");
            if dir {
                out.push(format!("{shown}/"));
                queue.push_back(path);
            } else {
                out.push(shown);
            }
            if out.len() >= MOST_LISTED {
                return out;
            }
        }
        if started.elapsed() > LIST_TIME {
            break;
        }
    }
    out
}

/// The `@` word the cursor is at the end of or inside: where its `@` is, and what follows it up to the cursor.
pub fn mention_at(text: &str, cursor: usize) -> Option<(usize, &str)> {
    let before = text.get(..cursor)?;
    let start = before.rfind(char::is_whitespace).map_or(0, |i| {
        i + before[i..].chars().next().map_or(1, char::len_utf8)
    });
    let word = &before[start..];
    let query = word.strip_prefix('@')?;
    Some((start, query.trim_start_matches('"')))
}

/// The end of the word that starts at `start`.
pub fn word_end(text: &str, start: usize) -> usize {
    text[start..]
        .find(char::is_whitespace)
        .map_or(text.len(), |i| start + i)
}

/// How a path is written after `@`: in quotes when it has a space.
pub fn written(path: &str) -> String {
    if path.contains(char::is_whitespace) {
        format!("@\"{path}\"")
    } else {
        format!("@{path}")
    }
}

/// The paths that match `query`, best first: a name that starts with it, a path that starts with it, a
/// path that contains it, then a path with its letters in order. Shorter paths first among equals.
/// With nothing typed, the entries at the top of the folder.
pub fn rank<'a>(files: &'a [String], query: &str, most: usize) -> Vec<&'a str> {
    let query = query.to_lowercase();
    let mut ranked: Vec<(u8, usize, &str)> = Vec::new();
    for path in files {
        let lower = path.to_lowercase();
        let trimmed = lower.trim_end_matches('/');
        let name = trimmed.rsplit('/').next().unwrap_or(trimmed);
        let rank = if query.is_empty() {
            if trimmed.contains('/') {
                continue;
            }
            0
        } else if name.starts_with(&query) {
            0
        } else if lower.starts_with(&query) {
            // `src/` lists what is in the folder, not the folder again.
            if lower == query {
                continue;
            }
            1
        } else if lower.contains(&query) {
            2
        } else if in_order(&lower, &query) {
            3
        } else {
            continue;
        };
        ranked.push((rank, path.len(), path));
    }
    ranked.sort();
    ranked.into_iter().take(most).map(|(_, _, p)| p).collect()
}

fn in_order(text: &str, wanted: &str) -> bool {
    let mut letters = text.chars();
    wanted.chars().all(|w| letters.any(|c| c == w))
}

/// The paths named with `@` in a message, in order and once each. `@"a b.txt"` names a path with a space.
pub fn mentions(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut at = 0;
    while let Some(i) = text[at..].find('@') {
        let start = at + i;
        at = start + 1;
        let starts_word = text[..start]
            .chars()
            .next_back()
            .is_none_or(char::is_whitespace);
        if !starts_word {
            continue;
        }
        let rest = &text[start + 1..];
        let path = if let Some(quoted) = rest.strip_prefix('"') {
            match quoted.find('"') {
                Some(end) => quoted[..end].to_string(),
                None => continue,
            }
        } else {
            rest[..rest.find(char::is_whitespace).unwrap_or(rest.len())].to_string()
        };
        if !path.is_empty() && !out.contains(&path) {
            out.push(path);
        }
    }
    out
}

/// A message with the files it names.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Attached {
    /// The message and the files' text, for the model. None when no file was named.
    pub content: Option<String>,
    /// The paths that were attached.
    pub files: Vec<String>,
    /// Plain sentences about files that were named but could not go.
    pub problems: Vec<String>,
}

/// Reads the files `text` names with `@`, from `workspace`. A word that is not a path, such as `@pip`,
/// is left alone.
pub fn attach(text: &str, workspace: &Path) -> Attached {
    let mut out = Attached::default();
    let mut blocks = String::new();
    for mention in mentions(text) {
        let Some((written, path)) = resolve(&mention, workspace) else {
            continue;
        };
        if out.files.contains(&written) {
            continue;
        }
        let block = if path.is_dir() {
            folder_block(&written, &path)
        } else {
            match file_block(&written, &path) {
                Ok(block) => block,
                Err(why) => {
                    out.problems
                        .push(format!("@{written} was not attached: {why}"));
                    continue;
                }
            }
        };
        if blocks.len() + block.len() > MOST_ALL {
            out.problems.push(format!(
                "@{written} was not attached: the files of one message can be {} KB together.",
                MOST_ALL / 1024
            ));
            continue;
        }
        blocks.push_str(&block);
        out.files.push(written);
    }
    if !out.files.is_empty() {
        out.content = Some(format!("{text}{ATTACHED}\n{blocks}{ATTACHED_END}"));
    }
    out
}

/// The path a mention names, as written and on disk. Punctuation after it (`see @a.txt.`) is not part of it.
fn resolve(mention: &str, workspace: &Path) -> Option<(String, PathBuf)> {
    let mut written = mention.to_string();
    loop {
        let path = PathBuf::from(expand(
            &written,
            workspace,
            directories::BaseDirs::new().as_ref().map(|d| d.home_dir()),
        ));
        let path = if path.is_absolute() {
            path
        } else {
            workspace.join(path)
        };
        if path.exists() {
            return Some((written.trim_end_matches('/').to_string(), path));
        }
        let last = written.chars().next_back()?;
        if !".,;:!?)]}'\"".contains(last) {
            return None;
        }
        written.pop();
    }
}

fn file_block(written: &str, path: &Path) -> Result<String, String> {
    let size = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
    if size > MOST_FILE {
        return Err(format!(
            "it is {} KB, and a file can be {} KB.",
            size / 1024,
            MOST_FILE / 1024
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    if bytes.contains(&0) {
        return Err("it is not text.".into());
    }
    let text = String::from_utf8(bytes).map_err(|_| "it is not text.".to_string())?;
    Ok(format!(
        "<file path=\"{written}\">\n{}\n</file>\n",
        text.trim_end_matches('\n')
    ))
}

fn folder_block(written: &str, path: &Path) -> String {
    let mut names: Vec<String> = std::fs::read_dir(path)
        .map(|read| {
            read.filter_map(|e| {
                let e = e.ok()?;
                let name = e.file_name().to_string_lossy().to_string();
                let dir = e.file_type().ok()?.is_dir();
                Some(if dir { format!("{name}/") } else { name })
            })
            .collect()
        })
        .unwrap_or_default();
    names.sort();
    let more = names.len().saturating_sub(MOST_ENTRIES);
    names.truncate(MOST_ENTRIES);
    let mut block = format!("<directory path=\"{written}/\">\n");
    for n in names {
        block.push_str(&n);
        block.push('\n');
    }
    if more > 0 {
        block.push_str(&format!("… and {more} more\n"));
    }
    block.push_str("</directory>\n");
    block
}

/// A message as the chat shows it: what was written, and the paths of the files that went with it.
pub fn shown(content: &str) -> (&str, Vec<&str>) {
    let Some((text, files)) = content.split_once(ATTACHED) else {
        return (content, Vec::new());
    };
    let paths = files
        .lines()
        .filter_map(|l| {
            l.strip_prefix("<file path=\"")
                .or_else(|| l.strip_prefix("<directory path=\""))
        })
        .filter_map(|l| l.strip_suffix("\">"))
        .collect();
    (text, paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "imp-mentions-{}-{}",
            std::process::id(),
            rand::random::<u32>()
        ));
        for (rel, text) in [
            ("notes.txt", "remember milk"),
            ("src/main.rs", "fn main() {}"),
            ("src/lib.rs", "// lib"),
            ("my file.md", "spaced"),
            (".secret", "no"),
            ("node_modules/x/index.js", "no"),
        ] {
            let path = dir.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        std::fs::write(dir.join("blob.bin"), [0u8, 1, 2]).unwrap();
        dir
    }

    #[test]
    fn the_folder_is_listed_without_hidden_files_and_build_output() {
        let dir = folder();
        let files = list_files(&dir);
        assert!(files.contains(&"notes.txt".to_string()), "{files:?}");
        assert!(files.contains(&"src/".to_string()));
        assert!(files.contains(&"src/main.rs".to_string()));
        assert!(
            !files
                .iter()
                .any(|f| f.contains("secret") || f.contains("node_modules"))
        );
        assert_eq!(rank(&files, "main", 5), ["src/main.rs"]);
        assert_eq!(rank(&files, "src/", 5), ["src/lib.rs", "src/main.rs"]);
        assert_eq!(rank(&files, "smr", 5), ["src/main.rs"]);
        assert!(!rank(&files, "", 50).contains(&"src/main.rs"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_word_at_the_cursor() {
        assert_eq!(mention_at("see @no", 7), Some((4, "no")));
        assert_eq!(mention_at("@", 1), Some((0, "")));
        assert_eq!(mention_at("me@mail", 7), None);
        assert_eq!(mention_at("@a b", 4), None);
        assert_eq!(word_end("x @abc def", 2), 6);
        assert_eq!(written("a b.md"), "@\"a b.md\"");
    }

    #[test]
    fn named_files_go_with_the_message_and_others_are_left_alone() {
        let dir = folder();
        assert_eq!(
            mentions("read @notes.txt, @\"my file.md\" and mail me@x.org @pip"),
            ["notes.txt,", "my file.md", "pip"]
        );
        let sent = attach(
            "Read @notes.txt, then @\"my file.md\" and @src. Ask @pip. @blob.bin",
            &dir,
        );
        assert_eq!(sent.files, ["notes.txt", "my file.md", "src"]);
        assert!(sent.problems[0].contains("not text"), "{:?}", sent.problems);
        let content = sent.content.unwrap();
        assert!(content.contains("<file path=\"notes.txt\">\nremember milk\n</file>"));
        assert!(content.contains("<directory path=\"src/\">\nlib.rs\nmain.rs\n"));
        let (text, files) = shown(&content);
        assert_eq!(
            text,
            "Read @notes.txt, then @\"my file.md\" and @src. Ask @pip. @blob.bin"
        );
        assert_eq!(files, ["notes.txt", "my file.md", "src/"]);
        assert_eq!(attach("hello @nobody", &dir), Attached::default());
        assert_eq!(shown("plain"), ("plain", vec![]));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
