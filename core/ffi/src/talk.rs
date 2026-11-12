//! Whether a message between two Imps goes on in their latest conversation.

use imp_core::talk::{MAX_WINDOW_MINUTES, Threading};

/// Continue the latest conversation (true) or start a new one (false). `threading` is the stored
/// setting (`decides`, `recent`, `always`, `never`), `asked` the sender's `conversation` argument,
/// `last` when the latest conversation last had a message, in seconds.
#[uniffi::export]
pub fn talk_continues(
    threading: String,
    asked: Option<String>,
    last: Option<u64>,
    window_minutes: u32,
    now: u64,
) -> bool {
    Threading::from_name(&threading).continues(asked.as_deref(), last, window_minutes, now)
}

/// The most the window can be: a week.
#[uniffi::export]
pub fn talk_max_window_minutes() -> u32 {
    MAX_WINDOW_MINUTES
}
