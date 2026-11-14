//! The book file and the key store: where a device keeps its links and its secret seed.

use crate::{CliError, Result};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

/// Where the device's secret seed is kept. The real one is the platform's key store.
pub trait SeedStore: Send + Sync {
    /// The saved seed, or None the first time. The error is a plain sentence for the user.
    fn get(&self) -> std::result::Result<Option<String>, String>;
    fn set(&self, seed: &str) -> std::result::Result<(), String>;
}

const BOOK_FILE: &str = "link-book";
const SEED_SERVICE: &str = "imp";
const SEED_ACCOUNT: &str = "link-identity";

/// The key store of the system: the Keychain, the Credential Manager or the Secret Service.
///
/// The book in the usual data folder keeps its seed under `imp` / `link-identity`, as it always has. A book
/// in another folder (`--data-dir`, `IMP_DATA_DIR`) gets an account of its own, named after the folder, so
/// trying another folder never replaces the seed of the usual book.
pub struct SystemSeedStore {
    account: String,
}

impl SystemSeedStore {
    /// The store for the book in `dir`.
    pub fn for_dir(dir: &Path) -> Self {
        Self {
            account: seed_account(dir, crate::serve::default_data_dir().ok().as_deref()),
        }
    }

    fn entry(&self) -> std::result::Result<keyring::Entry, String> {
        keyring::Entry::new(SEED_SERVICE, &self.account).map_err(|_| no_key_store())
    }
}

/// The key store account for the book in `dir`, given the usual data folder.
fn seed_account(dir: &Path, usual: Option<&Path>) -> String {
    let canonical = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    if usual.is_some_and(|u| canonical(u) == canonical(dir)) {
        return SEED_ACCOUNT.to_string();
    }
    let hash = canonical(dir)
        .to_string_lossy()
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
        });
    format!("{SEED_ACCOUNT}-{hash:016x}")
}

fn no_key_store() -> String {
    "Imp keeps this device's secret in the system key store, and none is available. On Linux, start a Secret Service such as GNOME Keyring or KWallet (it needs a logged-in desktop session), then run the command again.".into()
}

impl SeedStore for SystemSeedStore {
    fn get(&self) -> std::result::Result<Option<String>, String> {
        match self.entry()?.get_password() {
            Ok(seed) => Ok(Some(seed)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(no_key_store()),
        }
    }

    fn set(&self, seed: &str) -> std::result::Result<(), String> {
        self.entry()?.set_password(seed).map_err(|_| no_key_store())
    }
}

/// Where the node's book is kept: a file in the data folder that only the owner can read, without the
/// device's secret seed. The seed lives in the key store and is joined to the book when it is read. It is
/// never printed and never written to a file. With no key store the book cannot be used at all.
pub struct BookFile {
    path: PathBuf,
    seeds: Arc<dyn SeedStore>,
}

impl BookFile {
    pub fn in_dir(dir: &Path, seeds: Arc<dyn SeedStore>) -> Self {
        Self {
            path: dir.join(BOOK_FILE),
            seeds,
        }
    }

    /// The saved book with its seed put back, or None the first time.
    pub fn load(&self) -> Result<Option<Vec<u8>>> {
        let seed = self.seeds.get().map_err(CliError)?;
        let bytes = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                return Err(CliError(format!(
                    "Could not read {}: {e}",
                    self.path.display()
                )));
            }
        };
        let damaged = || {
            CliError(format!(
                "The link book in {} cannot be used. Remove the file to start again.",
                self.path.display()
            ))
        };
        let mut book: serde_json::Map<String, serde_json::Value> =
            serde_json::from_slice(&bytes).map_err(|_| damaged())?;
        if book.contains_key("seed") {
            return Err(damaged());
        }
        let seed = seed.ok_or_else(|| {
            CliError(format!(
                "This device's secret is not in the system key store, so the link book in {} cannot be used. Remove the file to start again.",
                self.path.display()
            ))
        })?;
        book.insert(
            "seed".into(),
            serde_json::from_str(&seed).map_err(|_| damaged())?,
        );
        serde_json::to_vec(&book).map(Some).map_err(|_| damaged())
    }

    /// Writes the book whole: the seed to the key store, then the rest to a private temporary file and a
    /// rename, so a crash never leaves half.
    pub fn save(&self, bytes: &[u8]) -> Result<()> {
        use std::io::Write;
        let mut book: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(bytes)
            .map_err(|_| CliError("The link book could not be saved.".into()))?;
        let seed = book
            .remove("seed")
            .and_then(|s| serde_json::to_string(&s).ok())
            .ok_or_else(|| CliError("The link book could not be saved.".into()))?;
        if self.seeds.get().map_err(CliError)?.as_deref() != Some(seed.as_str()) {
            self.seeds.set(&seed).map_err(CliError)?;
        }
        let rest = serde_json::to_vec(&book)
            .map_err(|_| CliError("The link book could not be saved.".into()))?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let temporary = self.path.with_extension("new");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&rest)?;
        file.sync_all()?;
        std::fs::rename(&temporary, &self.path)?;
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// A new random id (version 4): a device's on its first run, an Imp's, a turn's.
pub fn new_device_id() -> Uuid {
    uuid::Builder::from_random_bytes(rand::random()).into_uuid()
}

#[cfg(test)]
mod tests {
    use super::*;
    use imp_core::link::book::LinkBook;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Memory(Mutex<Option<String>>);

    impl SeedStore for Memory {
        fn get(&self) -> std::result::Result<Option<String>, String> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn set(&self, seed: &str) -> std::result::Result<(), String> {
            *self.0.lock().unwrap() = Some(seed.to_string());
            Ok(())
        }
    }

    struct Missing;

    impl SeedStore for Missing {
        fn get(&self) -> std::result::Result<Option<String>, String> {
            Err(no_key_store())
        }
        fn set(&self, _: &str) -> std::result::Result<(), String> {
            Err(no_key_store())
        }
    }

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("imp-book-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_book_in_another_folder_keeps_its_seed_apart() {
        let usual = std::env::temp_dir();
        assert_eq!(seed_account(&usual, Some(&usual)), SEED_ACCOUNT);
        let other = usual.join("imp-elsewhere");
        let account = seed_account(&other, Some(&usual));
        assert!(account.starts_with("link-identity-") && account != SEED_ACCOUNT);
        assert_eq!(
            account,
            seed_account(&other, Some(&usual)),
            "the same every time"
        );
        assert_ne!(
            account,
            seed_account(&usual.join("imp-third"), Some(&usual))
        );
        assert_ne!(seed_account(&usual, None), SEED_ACCOUNT);
    }

    #[test]
    fn the_seed_goes_to_the_key_store_and_never_into_the_file() {
        let dir = folder("seed");
        let store = Arc::new(Memory::default());
        let file = BookFile::in_dir(&dir, store.clone());
        assert!(file.load().unwrap().is_none());
        let book = LinkBook::new(Uuid::from_u128(5), [0x5a; 32], [7; 32]);
        let whole = book.write();
        file.save(&whole).unwrap();
        let on_disk = std::fs::read_to_string(file.path()).unwrap();
        assert!(!on_disk.contains("seed"), "{on_disk}");
        assert!(
            store
                .0
                .lock()
                .unwrap()
                .as_deref()
                .is_some_and(|s| !s.is_empty())
        );
        let seed_text = store.0.lock().unwrap().clone().unwrap();
        assert!(!on_disk.contains(seed_text.trim_matches('"')));
        let back = LinkBook::read(&file.load().unwrap().unwrap()).unwrap();
        assert_eq!(back, book);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn with_no_key_store_it_says_what_to_do_and_writes_nothing() {
        let dir = folder("missing");
        let file = BookFile::in_dir(&dir, Arc::new(Missing));
        let said = file.load().unwrap_err().0;
        assert!(said.contains("system key store"), "{said}");
        assert!(said.contains("Secret Service"), "{said}");
        let book = LinkBook::new(Uuid::from_u128(5), [1; 32], [2; 32]).write();
        assert!(file.save(&book).is_err());
        assert!(!file.path().exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_book_whose_secret_is_gone_is_not_used() {
        let dir = folder("gone");
        let file = BookFile::in_dir(&dir, Arc::new(Memory::default()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(file.path(), b"{\"device\":\"x\"}").unwrap();
        assert!(
            file.load()
                .unwrap_err()
                .0
                .contains("not in the system key store")
        );
        std::fs::write(file.path(), b"{\"seed\":\"AAAA\"}").unwrap();
        assert!(file.load().unwrap_err().0.contains("cannot be used"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
