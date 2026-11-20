//! The process's environment as a value, so folders and variables can be found (and tested) without
//! touching the real one.

use crate::config::subst::Sources;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
pub struct Env {
    vars: BTreeMap<String, String>,
    home: Option<PathBuf>,
    windows: bool,
}

impl Env {
    /// The real environment of this process.
    pub fn process() -> Self {
        let vars: BTreeMap<String, String> = std::env::vars().collect();
        let windows = cfg!(windows);
        let home = vars
            .get(if windows { "USERPROFILE" } else { "HOME" })
            .filter(|h| !h.is_empty())
            .map(PathBuf::from);
        Self {
            vars,
            home,
            windows,
        }
    }

    /// A made-up environment (Unix rules), for tests and for callers that know better.
    pub fn new(vars: &[(&str, &str)], home: Option<&Path>) -> Self {
        Self {
            vars: vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            home: home.map(Path::to_path_buf),
            windows: false,
        }
    }

    /// The same environment with Windows rules for the config folder (`%APPDATA%\imp`).
    pub fn on_windows(mut self) -> Self {
        self.windows = true;
        self
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.vars
            .get(name)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    pub fn home_dir(&self) -> Option<&Path> {
        self.home.as_deref()
    }

    /// `$IMP_CONFIG_HOME`, else `$XDG_CONFIG_HOME/imp`, else `~/.config/imp` (`%APPDATA%\imp` on Windows).
    pub fn config_dir(&self) -> Option<PathBuf> {
        if let Some(dir) = self.get("IMP_CONFIG_HOME") {
            return Some(PathBuf::from(dir));
        }
        if self.windows {
            return self.get("APPDATA").map(|d| Path::new(d).join("imp"));
        }
        if let Some(dir) = self.get("XDG_CONFIG_HOME") {
            return Some(Path::new(dir).join("imp"));
        }
        self.home.as_ref().map(|h| h.join(".config").join("imp"))
    }

    /// `~/.agents`: the person's own agents, skills, commands and `AGENTS.md`.
    pub fn agents_dir(&self) -> Option<PathBuf> {
        self.home.as_ref().map(|h| h.join(".agents"))
    }
}

impl Sources for Env {
    fn var(&self, name: &str) -> Option<String> {
        self.vars.get(name).cloned()
    }

    fn read(&self, path: &Path) -> std::io::Result<String> {
        std::fs::read_to_string(path)
    }

    fn home(&self) -> Option<&Path> {
        self.home_dir()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_config_folder_follows_the_order() {
        let home = Path::new("/h");
        let all = Env::new(
            &[("IMP_CONFIG_HOME", "/c"), ("XDG_CONFIG_HOME", "/x")],
            Some(home),
        );
        assert_eq!(all.config_dir().unwrap(), Path::new("/c"));
        let xdg = Env::new(&[("XDG_CONFIG_HOME", "/x")], Some(home));
        assert_eq!(xdg.config_dir().unwrap(), Path::new("/x/imp"));
        let none = Env::new(&[("XDG_CONFIG_HOME", "")], Some(home));
        assert_eq!(none.config_dir().unwrap(), Path::new("/h/.config/imp"));
        assert_eq!(Env::new(&[], None).config_dir(), None);
        let win = Env::new(
            &[("APPDATA", "C:/A"), ("XDG_CONFIG_HOME", "/x")],
            Some(home),
        )
        .on_windows();
        assert_eq!(win.config_dir().unwrap(), Path::new("C:/A/imp"));
        assert_eq!(none.agents_dir().unwrap(), Path::new("/h/.agents"));
    }
}
