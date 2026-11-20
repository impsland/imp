//! Writing the configuration: `imp.json` in a fixed form, `auth.json` readable by the person only,
//! and the agent files. Every write is a temporary file in the same folder and a rename, made under an
//! advisory lock (`imp.json.lock` in the config folder) and after reading the file again, so two
//! programs never undo each other and a reader never sees half a file.

use crate::config::Env;
use crate::config::doc::{Agent, valid_agent_name};
use crate::config::types::{Auth, ImpConfig};
use serde::Serialize;
use serde_json::Value;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    /// A file that is there and cannot be read as it is. It is not written over.
    #[error("{} is not valid: {message}", path.display())]
    Invalid { path: PathBuf, message: String },
    #[error("there is no folder to keep this in")]
    NoFolder,
    #[error("{0}")]
    Refused(String),
}

fn io(path: &Path) -> impl FnOnce(std::io::Error) -> ConfigError + '_ {
    move |source| ConfigError::Io {
        path: path.to_path_buf(),
        source,
    }
}

/// `imp.json` as written: the known keys in the order of the format, then any the core does not know, sorted;
/// every object below them sorted by key, two spaces, and a newline at the end.
pub fn to_json(config: &ImpConfig) -> String {
    json_text(config, &TOP_KEYS)
}

/// The keys `imp.json` starts with, in this order.
const TOP_KEYS: [&str; 10] = [
    "model",
    "providers",
    "mcp",
    "permissions",
    "imps",
    "triggers",
    "animations",
    "requests",
    "talk",
    "link",
];

fn json_text<T: Serialize>(value: &T, first: &[&str]) -> String {
    let Ok(Value::Object(map)) = serde_json::to_value(value) else {
        return "{}\n".into();
    };
    // Objects below the first level are sorted by `serde_json` itself; the first level is written by
    // hand, since `first` is not alphabetical.
    let mut entries: Vec<(String, Value)> = map.into_iter().collect();
    let rank = |k: &str| first.iter().position(|f| *f == k).unwrap_or(first.len());
    entries.sort_by(|a, b| rank(&a.0).cmp(&rank(&b.0)).then_with(|| a.0.cmp(&b.0)));
    if entries.is_empty() {
        return "{}\n".into();
    }
    let lines: Vec<String> = entries
        .iter()
        .map(|(k, v)| {
            let key = serde_json::to_string(k).unwrap_or_default();
            let value = serde_json::to_string_pretty(v)
                .unwrap_or_default()
                .replace('\n', "\n  ");
            format!("  {key}: {value}")
        })
        .collect();
    format!("{{\n{}\n}}\n", lines.join(",\n"))
}

/// Writes `bytes` to `path` by writing a file beside it and renaming it over. With `private` the file
/// is readable by its owner only (0600 on Unix).
pub fn write_atomic(path: &Path, bytes: &[u8], private: bool) -> Result<(), ConfigError> {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(io(dir))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let temp = dir.join(format!(
        ".{name}.{}-{:08x}.tmp",
        std::process::id(),
        rand::random::<u32>()
    ));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        if private {
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        }
        #[cfg(not(unix))]
        let _ = private;
        let mut file = options.open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temp, path)
    })();
    if let Err(source) = result {
        let _ = std::fs::remove_file(&temp);
        return Err(ConfigError::Io {
            path: path.to_path_buf(),
            source,
        });
    }
    Ok(())
}

/// The lock; it is let go when this is dropped.
struct Lock(File);

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// Where the files are written: the config folder and `~/.agents`.
#[derive(Debug, Clone)]
pub struct Store {
    config_dir: PathBuf,
    agents_dir: PathBuf,
}

impl Store {
    pub fn new(config_dir: PathBuf, agents_dir: PathBuf) -> Self {
        Self {
            config_dir,
            agents_dir,
        }
    }

    /// The person's own folders. `Err` when the environment has no home folder to find them from.
    pub fn from_env(env: &Env) -> Result<Self, ConfigError> {
        match (env.config_dir(), env.agents_dir()) {
            (Some(c), Some(a)) => Ok(Self::new(c, a)),
            _ => Err(ConfigError::NoFolder),
        }
    }

    pub fn config_path(&self) -> PathBuf {
        self.config_dir.join("imp.json")
    }

    pub fn auth_path(&self) -> PathBuf {
        self.config_dir.join("auth.json")
    }

    pub fn agent_path(&self, name: &str) -> PathBuf {
        self.agents_dir.join("agents").join(format!("{name}.md"))
    }

    fn lock(&self) -> Result<Lock, ConfigError> {
        std::fs::create_dir_all(&self.config_dir).map_err(io(&self.config_dir))?;
        let path = self.config_dir.join("imp.json.lock");
        let file = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .map_err(io(&path))?;
        file.lock().map_err(io(&path))?;
        Ok(Lock(file))
    }

    /// `imp.json` as it is on disk, without filling anything in. Not there is the empty configuration.
    pub fn read_config(&self) -> Result<ImpConfig, ConfigError> {
        read_json(&self.config_path())
    }

    pub fn read_auth(&self) -> Result<Auth, ConfigError> {
        read_json(&self.auth_path())
    }

    /// Reads `imp.json` again under the lock, lets `change` edit it and writes it back, unless nothing
    /// changed. A file that is not valid is an error and is left alone.
    pub fn update<R>(&self, change: impl FnOnce(&mut ImpConfig) -> R) -> Result<R, ConfigError> {
        let _lock = self.lock()?;
        self.update_unlocked(change)
    }

    fn update_unlocked<R>(
        &self,
        change: impl FnOnce(&mut ImpConfig) -> R,
    ) -> Result<R, ConfigError> {
        let path = self.config_path();
        let mut config: ImpConfig = read_json(&path)?;
        let before = to_json(&config);
        let result = change(&mut config);
        let after = to_json(&config);
        if after != before || !path.exists() {
            write_atomic(&path, after.as_bytes(), false)?;
        }
        Ok(result)
    }

    /// The same for `auth.json`, which is written readable by the person only.
    pub fn update_auth<R>(&self, change: impl FnOnce(&mut Auth) -> R) -> Result<R, ConfigError> {
        let _lock = self.lock()?;
        let path = self.auth_path();
        let mut auth: Auth = read_json(&path)?;
        let before = json_text(&auth, &["providers", "mcp"]);
        let result = change(&mut auth);
        let after = json_text(&auth, &["providers", "mcp"]);
        if after != before || !path.exists() {
            write_atomic(&path, after.as_bytes(), true)?;
        }
        Ok(result)
    }

    fn checked_name(name: &str) -> Result<(), ConfigError> {
        if valid_agent_name(name) {
            Ok(())
        } else {
            Err(ConfigError::Refused(format!(
                "the name {name:?} is not allowed: use 1 to 32 letters, digits, - and _."
            )))
        }
    }

    /// An agent file as it is, without filling anything in.
    pub fn read_agent(&self, name: &str) -> Result<Agent, ConfigError> {
        Self::checked_name(name)?;
        let path = self.agent_path(name);
        let text = std::fs::read_to_string(&path).map_err(io(&path))?;
        Agent::parse(name, &text).map_err(|message| ConfigError::Invalid { path, message })
    }

    /// Writes the agent's file (`agent.name`), a new one or over the old.
    pub fn write_agent(&self, agent: &Agent) -> Result<(), ConfigError> {
        Self::checked_name(&agent.name)?;
        let _lock = self.lock()?;
        write_atomic(
            &self.agent_path(&agent.name),
            agent.to_markdown().as_bytes(),
            false,
        )
    }

    /// Reads the agent's file again under the lock (a new empty agent when there is none), lets `change`
    /// edit it and writes it back. A file that is not valid is an error and is left alone.
    pub fn update_agent<R>(
        &self,
        name: &str,
        change: impl FnOnce(&mut Agent) -> R,
    ) -> Result<R, ConfigError> {
        Self::checked_name(name)?;
        let _lock = self.lock()?;
        let path = self.agent_path(name);
        let mut agent = match std::fs::read_to_string(&path) {
            Ok(text) => Agent::parse(name, &text).map_err(|message| ConfigError::Invalid {
                path: path.clone(),
                message,
            })?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Agent {
                name: name.to_string(),
                ..Agent::default()
            },
            Err(source) => return Err(ConfigError::Io { path, source }),
        };
        let result = change(&mut agent);
        write_atomic(&path, agent.to_markdown().as_bytes(), false)?;
        Ok(result)
    }

    /// Renames the agent's file, and its settings in `imp.json` with it (the Imp keeps its id).
    pub fn rename_agent(&self, old: &str, new: &str) -> Result<(), ConfigError> {
        Self::checked_name(old)?;
        Self::checked_name(new)?;
        let _lock = self.lock()?;
        let (from, to) = (self.agent_path(old), self.agent_path(new));
        if !from.is_file() {
            return Err(ConfigError::Refused(format!("there is no agent {old}.")));
        }
        if to.exists() {
            return Err(ConfigError::Refused(format!(
                "there is already an agent {new}."
            )));
        }
        self.update_unlocked(|config| {
            if config.imps.contains_key(new) {
                return Err(ConfigError::Refused(format!(
                    "imp.json already has settings for {new}."
                )));
            }
            if let Some(extras) = config.imps.remove(old) {
                config.imps.insert(new.to_string(), extras);
            }
            Ok(())
        })??;
        std::fs::rename(&from, &to).map_err(io(&from))
    }

    /// Removes the agent's file and its settings in `imp.json`.
    pub fn remove_agent(&self, name: &str) -> Result<(), ConfigError> {
        Self::checked_name(name)?;
        let _lock = self.lock()?;
        let path = self.agent_path(name);
        std::fs::remove_file(&path).map_err(io(&path))?;
        self.update_unlocked(|config| {
            config.imps.remove(name);
        })
    }
}

fn read_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> Result<T, ConfigError> {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).map_err(|e| ConfigError::Invalid {
            path: path.to_path_buf(),
            // Only where it went wrong: the text may hold a key.
            message: format!("line {}, column {}", e.line(), e.column()),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(source) => Err(ConfigError::Io {
            path: path.to_path_buf(),
            source,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::types::{ImpExtras, ProviderAuth};
    use crate::config::{Effect, Rule};
    use std::sync::Arc;

    fn store(dir: &Path) -> Store {
        Store::new(dir.join("cfg"), dir.join("agents-home"))
    }

    #[test]
    fn json_is_deterministic() {
        let mut c = ImpConfig {
            model: Some("a/b".into()),
            ..ImpConfig::default()
        };
        c.mcp.insert(
            "z".into(),
            serde_json::from_str(r#"{"type":"remote","url":"u","headers":{"b":"2","a":"1"}}"#)
                .unwrap(),
        );
        c.mcp.insert(
            "a".into(),
            serde_json::from_str(r#"{"type":"local","command":["x"]}"#).unwrap(),
        );
        c.permissions.push(Rule::new("shell", "rm *", Effect::Deny));
        c.extra.insert(
            "zeta".into(),
            serde_json::json!({"y": 1, "x": [{"d": 1, "c": 2}]}),
        );
        c.extra.insert("alpha".into(), Value::Bool(true));
        let text = to_json(&c);
        assert_eq!(text, to_json(&c));
        assert!(
            text.starts_with("{\n  \"model\": \"a/b\",\n  \"mcp\": {\n    \"a\": {"),
            "{text}"
        );
        assert!(text.ends_with("}\n") && !text.ends_with("\n\n"));
        assert!(text.find("\"a\": \"1\"").unwrap() < text.find("\"b\": \"2\"").unwrap());
        assert!(text.find("\"alpha\"").unwrap() < text.find("\"zeta\"").unwrap());
        assert!(text.find("\"c\": 2").unwrap() < text.find("\"d\": 1").unwrap());
        // It reads back as the same, and writes back as the same text.
        let back: ImpConfig = serde_json::from_str(&text).unwrap();
        assert_eq!(back, c);
        assert_eq!(to_json(&back), text);
        assert_eq!(to_json(&ImpConfig::default()), "{}\n");
    }

    #[test]
    fn atomic_writes_leave_no_temp_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/f.txt");
        write_atomic(&path, b"one", false).unwrap();
        write_atomic(&path, b"two", false).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "two");
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["f.txt"]);
        // A folder where the file should be makes the rename fail, and the temp file goes away.
        let blocked = dir.path().join("blocked");
        std::fs::create_dir_all(blocked.join("inner")).unwrap();
        assert!(write_atomic(&blocked, b"x", false).is_err());
        assert_eq!(
            std::fs::read_dir(dir.path())
                .unwrap()
                .filter(|e| e
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp"))
                .count(),
            0
        );
    }

    #[cfg(unix)]
    #[test]
    fn auth_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        s.update_auth(|a| {
            a.providers
                .insert("p".into(), ProviderAuth { key: "k".into() });
        })
        .unwrap();
        let mode = |p: PathBuf| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(s.auth_path()), 0o600);
        s.update_auth(|a| a.providers.get_mut("p").unwrap().key = "k2".into())
            .unwrap();
        assert_eq!(mode(s.auth_path()), 0o600);
        assert_eq!(s.read_auth().unwrap().providers["p"].key, "k2");
        assert_ne!(
            mode(s.config_path().with_file_name("imp.json.lock")) & 0o077,
            0o777
        );
    }

    #[test]
    fn update_reads_again_and_skips_unchanged_writes() {
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        let n = s
            .update(|c| {
                c.model = Some("a/b".into());
                7
            })
            .unwrap();
        assert_eq!(n, 7);
        assert_eq!(
            std::fs::read_to_string(s.config_path()).unwrap(),
            "{\n  \"model\": \"a/b\"\n}\n"
        );
        // Someone else's change is not undone: the file is read inside the lock.
        std::fs::write(s.config_path(), r#"{"model":"a/b","future":1}"#).unwrap();
        s.update(|c| c.permissions.push(Rule::new("look", "*", Effect::Deny)))
            .unwrap();
        let text = std::fs::read_to_string(s.config_path()).unwrap();
        assert!(text.contains("\"future\": 1") && text.contains("\"look\""));
        // Nothing changed: the file is not touched.
        let before = std::fs::metadata(s.config_path())
            .unwrap()
            .modified()
            .unwrap();
        std::fs::write(s.config_path(), &text).unwrap();
        s.update(|_| ()).unwrap();
        assert_eq!(std::fs::read_to_string(s.config_path()).unwrap(), text);
        assert!(
            std::fs::metadata(s.config_path())
                .unwrap()
                .modified()
                .unwrap()
                >= before
        );
    }

    #[test]
    fn a_broken_file_is_not_written_over() {
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        std::fs::create_dir_all(dir.path().join("cfg")).unwrap();
        std::fs::write(s.config_path(), "{ \"model\": oops").unwrap();
        let err = s.update(|c| c.model = Some("a/b".into())).unwrap_err();
        assert!(matches!(err, ConfigError::Invalid { .. }), "{err}");
        assert_eq!(
            std::fs::read_to_string(s.config_path()).unwrap(),
            "{ \"model\": oops"
        );
    }

    #[test]
    fn concurrent_updates_all_land() {
        let dir = tempfile::tempdir().unwrap();
        let s = Arc::new(store(dir.path()));
        let threads: Vec<_> = (0..8)
            .map(|i| {
                let s = s.clone();
                std::thread::spawn(move || {
                    for j in 0..5 {
                        s.update(|c| {
                            c.permissions
                                .push(Rule::new("a", &format!("{i}-{j}"), Effect::Ask))
                        })
                        .unwrap();
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        assert_eq!(s.read_config().unwrap().permissions.len(), 40);
    }

    #[test]
    fn the_lock_excludes_others() {
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        let held = s.lock().unwrap();
        let other = File::options()
            .write(true)
            .open(dir.path().join("cfg/imp.json.lock"))
            .unwrap();
        assert!(matches!(
            other.try_lock(),
            Err(std::fs::TryLockError::WouldBlock)
        ));
        drop(held);
        assert!(other.try_lock().is_ok());
    }

    #[test]
    fn an_agent_is_updated_in_place_or_made() {
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        s.update_agent("pip", |a| a.body = "Hi".into()).unwrap();
        s.update_agent("pip", |a| a.description = Some("Small".into()))
            .unwrap();
        let a = s.read_agent("pip").unwrap();
        assert_eq!(
            (a.body.as_str(), a.description.as_deref()),
            ("Hi", Some("Small"))
        );
        assert!(s.update_agent("no way", |_| ()).is_err());
    }

    #[test]
    fn agents_are_written_renamed_and_removed() {
        let dir = tempfile::tempdir().unwrap();
        let s = store(dir.path());
        let mut agent =
            Agent::parse("pip", "---\ndescription: d\nfuture: 1\n---\nBody.\n\nMore.").unwrap();
        s.write_agent(&agent).unwrap();
        assert_eq!(s.read_agent("pip").unwrap(), agent);
        agent.model = Some("p/m".into());
        s.write_agent(&agent).unwrap();
        assert_eq!(s.read_agent("pip").unwrap().model.as_deref(), Some("p/m"));
        let id = ImpExtras::new().id;
        s.update(|c| {
            c.imps.insert("pip".into(), ImpExtras::with_id(id));
        })
        .unwrap();
        s.rename_agent("pip", "bit").unwrap();
        assert!(!s.agent_path("pip").exists());
        let moved = s.read_agent("bit").unwrap();
        assert_eq!(moved.body, "Body.\n\nMore.");
        assert_eq!(moved.extra["future"], 1);
        let config = s.read_config().unwrap();
        assert!(!config.imps.contains_key("pip"));
        assert_eq!(config.imps["bit"].id, id);
        // Refusals.
        s.write_agent(&Agent {
            name: "other".into(),
            ..Agent::default()
        })
        .unwrap();
        assert!(s.rename_agent("bit", "other").is_err());
        assert!(s.rename_agent("nope", "x").is_err());
        assert!(s.rename_agent("bit", "../x").is_err());
        assert!(
            s.write_agent(&Agent {
                name: "a/b".into(),
                ..Agent::default()
            })
            .is_err()
        );
        s.remove_agent("bit").unwrap();
        assert!(!s.agent_path("bit").exists() && s.read_config().unwrap().imps.is_empty());
        assert!(s.remove_agent("bit").is_err());
    }
}
