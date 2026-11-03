//! Messages from one Imp to another and the conversations they make. Follows Swift
//! `TalkThreading`: a message either goes on in the latest conversation of the two or starts a new one.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// The most a window can be: a week.
pub const MAX_WINDOW_MINUTES: u32 = 10_080;
/// The most messages kept in one conversation.
const KEEP_MESSAGES: usize = 200;

/// Who decides between continuing and starting new.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Threading {
    /// The sending Imp says, and if it says nothing the recent rule applies.
    #[default]
    Decides,
    /// Continue if the last message is younger than the window.
    Recent,
    Always,
    Never,
}

impl Threading {
    /// Continue the latest conversation (true) or start a new one (false). `asked` is the
    /// `conversation` argument of the sender. `last` is when the latest conversation last had
    /// a message, in seconds. With no earlier conversation the answer is always false.
    pub fn continues(
        self,
        asked: Option<&str>,
        last: Option<u64>,
        window_minutes: u32,
        now: u64,
    ) -> bool {
        let Some(last) = last else { return false };
        let window = u64::from(window_minutes.min(MAX_WINDOW_MINUTES)) * 60;
        let recent = now.saturating_sub(last) < window;
        match self {
            Self::Always => true,
            Self::Never => false,
            Self::Recent => recent,
            Self::Decides => match asked.map(|a| a.trim().to_lowercase()).as_deref() {
                Some("new") => false,
                Some("continue") => true,
                _ => recent,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TalkMessage {
    /// The name of the Imp that wrote it.
    pub from: String,
    pub text: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Conversation {
    pub started: u64,
    pub updated: u64,
    pub messages: Vec<TalkMessage>,
}

/// All conversations between two Imps.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairLog {
    pub conversations: Vec<Conversation>,
}

impl PairLog {
    /// When the latest conversation last had a message.
    pub fn last_activity(&self) -> Option<u64> {
        self.conversations.last().map(|c| c.updated)
    }

    /// The conversation a message at `now` goes into: the latest one or a fresh one.
    pub fn open(&mut self, continue_latest: bool, now: u64) -> &mut Conversation {
        if !(continue_latest && !self.conversations.is_empty()) {
            self.conversations.push(Conversation {
                started: now,
                updated: now,
                messages: Vec::new(),
            });
        }
        self.conversations.last_mut().expect("a conversation")
    }
}

impl Conversation {
    pub fn push(&mut self, from: &str, text: &str, now: u64) {
        self.messages.push(TalkMessage {
            from: from.to_string(),
            text: text.to_string(),
        });
        if self.messages.len() > KEEP_MESSAGES {
            let extra = self.messages.len() - KEEP_MESSAGES;
            self.messages.drain(..extra);
        }
        self.updated = now;
    }
}

/// Conversations on disk, one file per pair of Imps, in a folder.
#[derive(Debug, Clone)]
pub struct TalkStore {
    dir: PathBuf,
}

fn clean(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

impl TalkStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The file of a pair. The order of the names does not matter.
    pub fn path(&self, a: &str, b: &str) -> PathBuf {
        let (mut a, mut b) = (clean(a), clean(b));
        if a > b {
            std::mem::swap(&mut a, &mut b);
        }
        self.dir.join(format!("{a}--{b}.json"))
    }

    /// A missing or unreadable file gives an empty log.
    pub fn load(&self, a: &str, b: &str) -> PairLog {
        std::fs::read_to_string(self.path(a, b))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, a: &str, b: &str, log: &PairLog) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let text = serde_json::to_string_pretty(log).map_err(std::io::Error::other)?;
        std::fs::write(self.path(a, b), text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rule() {
        let (w, now) = (60, 10_000);
        let fresh = Some(now - 59 * 60);
        let old = Some(now - 61 * 60);
        assert!(!Threading::Decides.continues(Some("continue"), None, w, now));
        assert!(Threading::Decides.continues(None, fresh, w, now));
        assert!(!Threading::Decides.continues(None, old, w, now));
        assert!(Threading::Decides.continues(Some(" Continue "), old, w, now));
        assert!(!Threading::Decides.continues(Some("new"), fresh, w, now));
        assert!(Threading::Decides.continues(Some("other"), fresh, w, now));
        assert!(Threading::Recent.continues(Some("new"), fresh, w, now));
        assert!(Threading::Always.continues(Some("new"), old, w, now));
        assert!(!Threading::Never.continues(Some("continue"), fresh, w, now));
    }

    #[test]
    fn pairs_share_a_file_whatever_the_order() {
        let store = TalkStore::new("/x");
        assert_eq!(store.path("b", "a"), store.path("a", "b"));
        assert!(!store.path("../a", "b").to_string_lossy().contains(".."));
    }

    #[test]
    fn conversations_open_and_trim() {
        let mut log = PairLog::default();
        log.open(true, 5).push("a", "hi", 5);
        log.open(true, 9).push("b", "yo", 9);
        assert_eq!(log.conversations.len(), 1);
        assert_eq!(log.last_activity(), Some(9));
        log.open(false, 20);
        assert_eq!(log.conversations.len(), 2);
        let c = log.open(true, 30);
        for i in 0..250 {
            c.push("a", &i.to_string(), 30);
        }
        assert_eq!(c.messages.len(), KEEP_MESSAGES);
    }
}
