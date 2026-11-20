//! Where `imp` keeps its settings and its data.
//!
//! On Linux and Windows these are the system's usual folders for `imp` (`~/.config/imp`, `~/.local/share/imp`
//! and so on). On a Mac both would be `~/Library/Application Support/imp`, which is the Mac app's own `Imp`
//! folder, as file names on a Mac ignore case. Sharing it put the terminal app's settings and link
//! identity where the app's Factory Reset deletes everything. So on a Mac `imp` has a folder of its own,
//! `~/Library/Application Support/imp-chat`. The `imp` program moves the files it made in the shared
//! folder there when it starts ([`settle_here`]). The app's files stay where they are. Choosing a folder
//! never moves anything, so tests and other users of the library leave a person's files alone.
//!
//! `IMP_CONFIG_HOME` and `IMP_DATA_DIR` choose any other place.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The Mac folder of `imp`, in `~/Library/Application Support`.
pub const MAC_FOLDER: &str = "imp-chat";
/// The folder `imp` shared with the Mac app before it had its own.
pub const SHARED_FOLDER: &str = "imp";

/// What `imp` itself made in the shared folder: its settings, link, conversations between Imps, folder
/// trust. Everything else there is the Mac app's.
pub const OURS: &[&str] = &[
    "link-book",
    "link-identity",
    "link.lock",
    "talks",
    "trusted_folders.json",
];

/// What became of the move from the shared folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Settled {
    /// Nothing to move: the folder of its own is used.
    Own(PathBuf),
    /// These files were moved into the folder of its own, which is used.
    Moved(PathBuf, Vec<String>),
    /// Another `imp` is running from the shared folder: it stays in use until that one ends.
    Shared(PathBuf),
}

impl Settled {
    pub fn folder(&self) -> &Path {
        match self {
            Self::Own(p) | Self::Moved(p, _) | Self::Shared(p) => p,
        }
    }
}

/// The Mac folder for `imp` under `support` (`~/Library/Application Support`), with the files it left in
/// the shared folder moved into it first. A file already in the new folder is never replaced.
pub fn settle(support: &Path) -> Settled {
    let own = support.join(MAC_FOLDER);
    let shared = support.join(SHARED_FOLDER);
    let left: Vec<&str> = OURS
        .iter()
        .copied()
        .filter(|name| shared.join(name).exists() && !own.join(name).exists())
        .collect();
    if left.is_empty() {
        return Settled::Own(own);
    }
    // A running `imp` holds the lock of its link: moving its files under it would split its state.
    let _held = match hold_lock(&shared) {
        Some(lock) => lock,
        None => return Settled::Shared(shared),
    };
    if std::fs::create_dir_all(&own).is_err() {
        return Settled::Shared(shared);
    }
    let mut moved = Vec::new();
    for name in left {
        if std::fs::rename(shared.join(name), own.join(name)).is_ok() {
            moved.push(name.to_string());
        }
    }
    // What could not move keeps its old place, and so would the settings: use the shared folder then.
    if shared.join("link-book").exists() && !own.join("link-book").exists() {
        return Settled::Shared(shared);
    }
    Settled::Moved(own, moved)
}

/// The shared folder's link lock, when nobody holds it (or it is not there). None when another `imp` does.
fn hold_lock(shared: &Path) -> Option<Option<std::fs::File>> {
    let path = shared.join("link.lock");
    if !path.exists() {
        return Some(None);
    }
    let file = std::fs::File::options().write(true).open(&path).ok()?;
    match file.try_lock() {
        Ok(()) => Some(Some(file)),
        Err(_) => None,
    }
}

/// The Mac folder to use under `support`, without moving anything: its own folder, unless `imp`'s
/// settings or link are still only in the shared one (an older `imp` still running kept them there).
pub fn choose(support: &Path) -> PathBuf {
    let own = support.join(MAC_FOLDER);
    let shared = support.join(SHARED_FOLDER);
    let in_own = ["link-book"].iter().any(|n| own.join(n).exists());
    let in_shared = ["link-book"].iter().any(|n| shared.join(n).exists());
    if !in_own && in_shared { shared } else { own }
}

/// `~/Library/Application Support` on a Mac. None elsewhere.
fn mac_support() -> Option<PathBuf> {
    if cfg!(target_os = "macos") {
        directories::BaseDirs::new().map(|b| b.data_dir().to_path_buf())
    } else {
        None
    }
}

/// Moves `imp`'s files out of the folder it shared with the Mac app, once, when the program starts.
/// Says so on standard error when it moved something. Nothing happens on other systems.
pub fn settle_here() {
    let Some(support) = mac_support() else {
        return;
    };
    if let Settled::Moved(folder, files) = settle(&support)
        && !files.is_empty()
    {
        eprintln!(
            "imp moved its settings and link to {}, a folder of its own apart from the Mac app's.",
            folder.display()
        );
    }
}

/// The folder for settings and data on this computer, the same for the whole run.
fn usual() -> Option<&'static Path> {
    static FOLDER: OnceLock<Option<PathBuf>> = OnceLock::new();
    FOLDER
        .get_or_init(|| mac_support().map(|s| choose(&s)))
        .as_deref()
}

/// The usual settings folder: `~/Library/Application Support/imp-chat` on a Mac, `~/.config/imp` on Linux.
pub fn config_dir() -> Option<PathBuf> {
    match usual() {
        Some(folder) => Some(folder.to_path_buf()),
        None => directories::ProjectDirs::from("", "", "imp").map(|d| d.config_dir().to_path_buf()),
    }
}

/// The usual data folder: `~/Library/Application Support/imp-chat` on a Mac, `~/.local/share/imp` on Linux.
pub fn data_dir() -> Option<PathBuf> {
    match usual() {
        Some(folder) => Some(folder.to_path_buf()),
        None => directories::ProjectDirs::from("", "", "imp").map(|d| d.data_dir().to_path_buf()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn support(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "imp-folders-{tag}-{}-{}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(dir.join(SHARED_FOLDER)).unwrap();
        dir
    }

    fn write(path: PathBuf, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn our_files_move_out_and_the_apps_stay() {
        let base = support("move");
        let shared = base.join(SHARED_FOLDER);
        write(shared.join("trusted_folders.json"), "trust");
        write(shared.join("link-book"), "book");
        write(shared.join("link-identity"), "seed");
        write(shared.join("talks/pip.json"), "talk");
        // The Mac app's files.
        write(shared.join("link.json"), "app link");
        write(shared.join("keys.json"), "app keys");
        write(shared.join("Chats/a.json"), "app chat");
        let settled = settle(&base);
        let own = base.join(MAC_FOLDER);
        let Settled::Moved(folder, moved) = &settled else {
            panic!("{settled:?}");
        };
        assert_eq!(folder, &own);
        assert_eq!(
            moved,
            &[
                "link-book",
                "link-identity",
                "talks",
                "trusted_folders.json"
            ]
        );
        assert_eq!(
            std::fs::read_to_string(own.join("trusted_folders.json")).unwrap(),
            "trust"
        );
        assert!(own.join("talks/pip.json").exists());
        for app in ["link.json", "keys.json", "Chats/a.json"] {
            assert!(shared.join(app).exists(), "{app} stays the app's");
            assert!(!own.join(app).exists());
        }
        // Once moved, it is just used.
        assert_eq!(choose(&base), own);
        assert_eq!(settle(&base), Settled::Own(own));
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn nothing_is_replaced_and_a_running_imp_keeps_the_shared_folder() {
        let base = support("busy");
        let shared = base.join(SHARED_FOLDER);
        let own = base.join(MAC_FOLDER);
        write(shared.join("link-book"), "old");
        write(shared.join("link.lock"), "");
        // Another imp holds the lock: nothing moves, and the shared folder stays in use.
        let held = std::fs::File::options()
            .write(true)
            .open(shared.join("link.lock"))
            .unwrap();
        held.lock().unwrap();
        assert_eq!(settle(&base), Settled::Shared(shared.clone()));
        assert!(!own.exists());
        assert_eq!(choose(&base), shared, "used where its settings are");
        held.unlock().unwrap();
        // The new folder already has settings: they are kept, the old ones are left alone.
        write(own.join("link-book"), "new");
        write(shared.join("talks/a.json"), "talk");
        let Settled::Moved(_, moved) = settle(&base) else {
            panic!("moves what is missing");
        };
        assert_eq!(moved, &["link.lock", "talks"]);
        assert_eq!(
            std::fs::read_to_string(own.join("link-book")).unwrap(),
            "new"
        );
        assert_eq!(
            std::fs::read_to_string(shared.join("link-book")).unwrap(),
            "old"
        );
        // A Mac that never had imp in the shared folder.
        let fresh = support("fresh");
        assert_eq!(choose(&fresh), fresh.join(MAC_FOLDER));
        assert_eq!(settle(&fresh), Settled::Own(fresh.join(MAC_FOLDER)));
        let _ = std::fs::remove_dir_all(base);
        let _ = std::fs::remove_dir_all(fresh);
    }
}
