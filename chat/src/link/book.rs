//! The book file and the seed file: where a device keeps its links and its secret seed.

use crate::{CliError, Result};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

/// Where the device's secret seed is kept. The real one is [`SeedFile`].
pub trait SeedStore: Send + Sync {
    /// The saved seed, or None the first time. The error is a plain sentence for the user.
    fn get(&self) -> std::result::Result<Option<String>, String>;
    fn set(&self, seed: &str) -> std::result::Result<(), String>;
}

const BOOK_FILE: &str = "link-book";
const SEED_FILE: &str = "link-identity";
const SEED_SERVICE: &str = "imp";
const SEED_ACCOUNT: &str = "link-identity";

/// The device's seed in the file `link-identity` next to the book, which only the owner can read (as
/// `~/.ssh` keeps a key).
///
/// The seed is kept in a file, not the system key store. On macOS the Keychain asks for the login password
/// whenever a newly built `imp` reads it (every update). A seed still in the key
/// store is moved over once, and only by [`SeedFile::moving_from_keychain`], which the link commands use.
/// The chat never touches the key store: with the seed not moved yet, it says what to run instead.
pub struct SeedFile {
    dir: PathBuf,
    keychain: bool,
}

impl SeedFile {
    /// The seed of the book in `dir`. Never reads the key store.
    pub fn for_dir(dir: &Path) -> Self {
        Self {
            dir: dir.to_path_buf(),
            keychain: false,
        }
    }

    /// Like [`SeedFile::for_dir`], and moves a seed still kept in the system key store into the file.
    pub fn moving_from_keychain(dir: &Path) -> Self {
        Self {
            keychain: true,
            ..Self::for_dir(dir)
        }
    }

    fn path(&self) -> PathBuf {
        self.dir.join(SEED_FILE)
    }

    /// The entry the seed of this book was kept under in the key store, before it moved to a file.
    fn keychain_entry(&self) -> std::result::Result<keyring::Entry, String> {
        let account = seed_account(&self.dir, crate::serve::default_data_dir().ok().as_deref());
        keyring::Entry::new(SEED_SERVICE, &account).map_err(|_| no_key_store())
    }

    /// Moves the seed from the key store into the file. None when the key store has none.
    fn move_from_keychain(&self) -> std::result::Result<Option<String>, String> {
        let entry = self.keychain_entry()?;
        let seed = match entry.get_password() {
            Ok(seed) => seed,
            Err(keyring::Error::NoEntry) => return Ok(None),
            Err(_) => return Err(no_key_store()),
        };
        self.set(&seed)?;
        // The file has it now. A copy left behind (if this fails) is harmless and is never read again.
        let _ = entry.delete_credential();
        Ok(Some(seed))
    }
}

/// The key store account for the book in `dir`, given the usual data folder: `link-identity` for the usual
/// book, and one named after the folder for a book anywhere else.
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
    "This computer's link key is in the system key store from an older imp, and the key store can't be reached to move it. On Linux, start a Secret Service such as GNOME Keyring or KWallet (it needs a logged-in desktop session), then run `imp link` again.".into()
}

fn still_in_keychain() -> String {
    "this computer's link key is still in the system keychain, where an older imp kept it. Run `imp link` once to move it to a private file (your Mac may ask for your password one last time). After that the chat reaches your devices without asking.".into()
}

impl SeedStore for SeedFile {
    fn get(&self) -> std::result::Result<Option<String>, String> {
        let path = self.path();
        match std::fs::read_to_string(&path) {
            Ok(seed) => Ok(Some(seed.trim().to_string()).filter(|s| !s.is_empty())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if self.keychain {
                    self.move_from_keychain()
                } else if self.dir.join(BOOK_FILE).exists() {
                    // A book without a seed file was made by an older imp, which kept the seed in the key store.
                    Err(still_in_keychain())
                } else {
                    Ok(None)
                }
            }
            Err(e) => Err(format!("Could not read {}: {e}", path.display())),
        }
    }

    fn set(&self, seed: &str) -> std::result::Result<(), String> {
        let path = self.path();
        write_private(&path, seed.as_bytes())
            .map_err(|e| format!("Could not save {}: {e}", path.display()))
    }
}

/// Writes a file only the owner can read and write, through a temporary file and a rename, so a crash never
/// leaves half.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let temporary = path.with_extension("new");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    #[cfg(unix)]
    {
        // A file left from an older run keeps its mode on open, so set it again.
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)
}

/// Where the node's book is kept: a file in the data folder that only the owner can read, without the
/// device's secret seed. The seed is kept apart by a [`SeedStore`] and joined to the book when it is read.
/// It is never printed. Without its seed the book cannot be used at all.
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
                "This device's link key is missing, so the link book in {} cannot be used. Remove the file to start again.",
                self.path.display()
            ))
        })?;
        book.insert(
            "seed".into(),
            serde_json::from_str(&seed).map_err(|_| damaged())?,
        );
        serde_json::to_vec(&book).map(Some).map_err(|_| damaged())
    }

    /// Writes the book whole: the seed to its store, then the rest to a private temporary file and a rename,
    /// so a crash never leaves half.
    pub fn save(&self, bytes: &[u8]) -> Result<()> {
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
        write_private(&self.path, &rest)?;
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
    use imp_engine::link::book::LinkBook;
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
    fn the_seed_goes_to_its_store_and_never_into_the_book() {
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
        assert!(file.load().unwrap_err().0.contains("link key is missing"));
        std::fs::write(file.path(), b"{\"seed\":\"AAAA\"}").unwrap();
        assert!(file.load().unwrap_err().0.contains("cannot be used"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_seed_file_is_private_and_read_back() {
        let dir = folder("seed-file");
        let seeds = Arc::new(SeedFile::for_dir(&dir));
        assert_eq!(seeds.get().unwrap(), None, "nothing the first time");
        let file = BookFile::in_dir(&dir, seeds.clone());
        let book = LinkBook::new(Uuid::from_u128(9), [3; 32], [4; 32]);
        file.save(&book.write()).unwrap();
        assert!(seeds.get().unwrap().is_some_and(|s| !s.is_empty()));
        assert_eq!(
            LinkBook::read(&file.load().unwrap().unwrap()).unwrap(),
            book
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for name in [SEED_FILE, BOOK_FILE] {
                let mode = std::fs::metadata(dir.join(name))
                    .unwrap()
                    .permissions()
                    .mode();
                assert_eq!(mode & 0o777, 0o600, "{name}");
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_chat_never_asks_the_keychain_for_an_old_seed() {
        let dir = folder("old-book");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(BOOK_FILE), b"{\"device\":\"x\"}").unwrap();
        let said = SeedFile::for_dir(&dir).get().unwrap_err();
        assert!(said.contains("imp link"), "{said}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
