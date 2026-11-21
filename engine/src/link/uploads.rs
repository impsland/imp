//! Files a holder sends to an Imp's home (`upload` and `uploadPart`), kept in memory until the `ask`
//! that names them takes them. This is the home's side: it collects the parts, checks the size and the
//! checksum, and forgets what is never claimed. Nothing here is saved to the book.

use crate::workspace::checksum;
use std::collections::BTreeMap;
use uuid::Uuid;

/// The biggest file in bytes.
pub const MAX_UPLOAD: u64 = 25 << 20;
/// The most files one `ask` may name.
pub const MAX_ATTACHMENTS: usize = 4;
/// The biggest part in bytes.
pub const MAX_PART: usize = 1 << 20;
/// The most uploads in progress from one device.
pub const MAX_PER_DEVICE: usize = 8;
/// The most bytes pending in all.
pub const MAX_PENDING: u64 = 64 << 20;
/// Seconds an upload is kept after its last part.
pub const UPLOAD_LIFE: f64 = 10.0 * 60.0;
/// The longest file name in characters.
pub const MAX_NAME: usize = 160;

/// A file that arrived whole.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Upload {
    pub name: String,
    pub mime: String,
    pub data: Vec<u8>,
}

/// Why an upload was refused or dropped. The text goes to the sender.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    TooBig,
    TooMany,
    Busy,
    Empty,
    Repeated,
    OutOfOrder,
    Mismatch,
}

impl Refusal {
    pub fn reason(self) -> &'static str {
        match self {
            Self::TooBig => "That file is too big.",
            Self::TooMany => "Too many files are being sent.",
            Self::Busy => "The Imp is receiving too much right now.",
            Self::Empty => "That file is empty.",
            Self::Repeated => "That upload already started.",
            Self::OutOfOrder => "The file arrived out of order.",
            Self::Mismatch => "The file didn't arrive intact.",
        }
    }
}

struct Entry {
    from: Uuid,
    name: String,
    mime: String,
    size: u64,
    sha256: String,
    data: Vec<u8>,
    done: bool,
    last: f64,
}

#[derive(Default)]
pub struct Uploads {
    entries: BTreeMap<Uuid, Entry>,
}

/// A plain file name: no folders, no control characters, at most `MAX_NAME` characters.
pub fn clean_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let plain: String = base.chars().filter(|c| !c.is_control()).collect();
    let plain = plain.trim().trim_start_matches('.').trim();
    let cut: String = plain.chars().take(MAX_NAME).collect();
    if cut.is_empty() { "file".into() } else { cut }
}

impl Uploads {
    /// Starts an upload of `size` bytes from `from`.
    #[allow(clippy::too_many_arguments)]
    pub fn begin(
        &mut self,
        id: Uuid,
        from: Uuid,
        name: &str,
        mime: &str,
        size: u64,
        sha256: &str,
        now: f64,
    ) -> Result<(), Refusal> {
        if self.entries.contains_key(&id) {
            return Err(Refusal::Repeated);
        }
        if size == 0 {
            return Err(Refusal::Empty);
        }
        if size > MAX_UPLOAD {
            return Err(Refusal::TooBig);
        }
        if self.entries.values().filter(|e| e.from == from).count() >= MAX_PER_DEVICE {
            return Err(Refusal::TooMany);
        }
        if self.pending() + size > MAX_PENDING {
            return Err(Refusal::Busy);
        }
        self.entries.insert(
            id,
            Entry {
                from,
                name: clean_name(name),
                mime: mime.trim().to_string(),
                size,
                sha256: sha256.to_ascii_lowercase(),
                data: Vec::new(),
                done: false,
                last: now,
            },
        );
        Ok(())
    }

    /// Adds a part. An error means the upload is dropped. `None` means nothing to say: the part is
    /// not from the device that started the upload, or the upload is not known.
    pub fn part(
        &mut self,
        id: Uuid,
        from: Uuid,
        offset: u64,
        data: &[u8],
        now: f64,
    ) -> Option<Result<(), Refusal>> {
        let entry = self.entries.get_mut(&id).filter(|e| e.from == from)?;
        let fail = |this: &mut Self, why| {
            this.entries.remove(&id);
            Some(Err(why))
        };
        if entry.done
            || data.len() > MAX_PART
            || offset != entry.data.len() as u64
            || entry.data.len() as u64 + data.len() as u64 > entry.size
        {
            return fail(self, Refusal::OutOfOrder);
        }
        entry.data.extend_from_slice(data);
        entry.last = now;
        if entry.data.len() as u64 == entry.size {
            if checksum(&entry.data) != entry.sha256 {
                return fail(self, Refusal::Mismatch);
            }
            entry.done = true;
        }
        Some(Ok(()))
    }

    /// The file, if all of it arrived from `from`. It is forgotten after.
    pub fn take(&mut self, id: Uuid, from: Uuid) -> Option<Upload> {
        if !self
            .entries
            .get(&id)
            .is_some_and(|e| e.from == from && e.done)
        {
            return None;
        }
        let e = self.entries.remove(&id)?;
        Some(Upload {
            name: e.name,
            mime: e.mime,
            data: e.data,
        })
    }

    /// Forgets uploads that have waited too long since their last part.
    pub fn expire(&mut self, now: f64) {
        self.entries.retain(|_, e| now - e.last <= UPLOAD_LIFE);
    }

    /// Forgets the unfinished uploads of a device that went away.
    pub fn lost(&mut self, from: Uuid) {
        self.entries.retain(|_, e| e.from != from || e.done);
    }

    /// Bytes promised by all uploads held.
    pub fn pending(&self) -> u64 {
        self.entries.values().map(|e| e.size).sum()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn start(u: &mut Uploads, n: u128, from: u128, data: &[u8]) -> Result<(), Refusal> {
        u.begin(
            id(n),
            id(from),
            "a.png",
            "image/png",
            data.len() as u64,
            &checksum(data),
            0.0,
        )
    }

    #[test]
    fn names_are_plain() {
        assert_eq!(clean_name("../../etc/passwd"), "passwd");
        assert_eq!(clean_name("C:\\x\\cat.png"), "cat.png");
        assert_eq!(clean_name(".hidden"), "hidden");
        assert_eq!(clean_name("a\nb\u{0}.txt"), "ab.txt");
        assert_eq!(clean_name("/"), "file");
        assert_eq!(clean_name(&"x".repeat(500)).chars().count(), MAX_NAME);
    }

    #[test]
    fn parts_in_order_make_a_file_that_is_taken_once() {
        let mut u = Uploads::default();
        let data = b"hello world";
        start(&mut u, 1, 9, data).unwrap();
        assert!(u.take(id(1), id(9)).is_none());
        assert_eq!(u.part(id(1), id(9), 0, &data[..5], 1.0), Some(Ok(())));
        assert_eq!(u.part(id(1), id(9), 5, &data[5..], 2.0), Some(Ok(())));
        assert!(u.take(id(1), id(8)).is_none());
        let got = u.take(id(1), id(9)).unwrap();
        assert_eq!(
            (got.name.as_str(), got.mime.as_str(), got.data.as_slice()),
            ("a.png", "image/png", &data[..])
        );
        assert!(u.take(id(1), id(9)).is_none());
        assert!(u.is_empty());
    }

    #[test]
    fn a_bad_checksum_a_gap_or_a_surplus_drops_the_upload() {
        let mut u = Uploads::default();
        u.begin(id(1), id(9), "a", "x/y", 3, &checksum(b"abc"), 0.0)
            .unwrap();
        assert_eq!(
            u.part(id(1), id(9), 0, b"abd", 0.0),
            Some(Err(Refusal::Mismatch))
        );
        assert!(u.is_empty());
        start(&mut u, 2, 9, b"abc").unwrap();
        assert_eq!(
            u.part(id(2), id(9), 1, b"bc", 0.0),
            Some(Err(Refusal::OutOfOrder))
        );
        start(&mut u, 3, 9, b"abc").unwrap();
        assert_eq!(
            u.part(id(3), id(9), 0, b"abcd", 0.0),
            Some(Err(Refusal::OutOfOrder))
        );
        assert!(u.is_empty());
    }

    #[test]
    fn a_part_from_another_device_is_ignored_and_changes_nothing() {
        let mut u = Uploads::default();
        start(&mut u, 1, 9, b"abc").unwrap();
        assert_eq!(u.part(id(1), id(8), 0, b"abc", 0.0), None);
        assert_eq!(u.part(id(2), id(9), 0, b"abc", 0.0), None);
        assert_eq!(u.part(id(1), id(9), 0, b"abc", 0.0), Some(Ok(())));
    }

    #[test]
    fn the_limits_hold() {
        let mut u = Uploads::default();
        let sha = checksum(b"x");
        assert_eq!(
            u.begin(id(1), id(9), "a", "x/y", 0, &sha, 0.0),
            Err(Refusal::Empty)
        );
        assert_eq!(
            u.begin(id(1), id(9), "a", "x/y", MAX_UPLOAD + 1, &sha, 0.0),
            Err(Refusal::TooBig)
        );
        for n in 0..MAX_PER_DEVICE as u128 {
            u.begin(id(100 + n), id(9), "a", "x/y", 1, &sha, 0.0)
                .unwrap();
        }
        assert_eq!(
            u.begin(id(1), id(9), "a", "x/y", 1, &sha, 0.0),
            Err(Refusal::TooMany)
        );
        assert_eq!(
            u.begin(id(100), id(8), "a", "x/y", 1, &sha, 0.0),
            Err(Refusal::Repeated)
        );
        // Two devices fill most of the room with full-size files; a third waits.
        let mut u = Uploads::default();
        for n in 0..2 {
            u.begin(id(n), id(n + 10), "a", "x/y", MAX_UPLOAD, &sha, 0.0)
                .unwrap();
        }
        assert_eq!(
            u.begin(id(5), id(15), "a", "x/y", MAX_UPLOAD, &sha, 0.0),
            Err(Refusal::Busy)
        );
    }

    #[test]
    fn old_and_lost_uploads_go() {
        let mut u = Uploads::default();
        start(&mut u, 1, 9, b"abc").unwrap();
        start(&mut u, 2, 8, b"abc").unwrap();
        u.lost(id(8));
        assert_eq!(u.len(), 1);
        u.expire(UPLOAD_LIFE - 1.0);
        assert_eq!(u.len(), 1);
        u.expire(UPLOAD_LIFE + 1.0);
        assert!(u.is_empty());
    }
}
