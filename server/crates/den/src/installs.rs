//! Install counting: once per item per client per day, kept in memory and written in batches.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use imp_shared::ip::IpKey;
use moka::sync::Cache;
use sqlx::SqlitePool;

const SEEN_CAPACITY: u64 = 500_000;

struct DayKey {
    day: u64,
    key: [u8; 32],
}

pub struct Installs {
    day: Mutex<DayKey>,
    seen: Cache<u64, ()>,
    pending: Mutex<HashMap<i64, i64>>,
}

fn today() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or_default()
}

impl Installs {
    pub fn new() -> Self {
        Self {
            day: Mutex::new(DayKey {
                day: today(),
                key: rand::random(),
            }),
            seen: Cache::builder()
                .max_capacity(SEEN_CAPACITY)
                .time_to_live(Duration::from_secs(25 * 3600))
                .build(),
            pending: Mutex::default(),
        }
    }

    /// Counts an install of `item` by `client` unless this client already did today.
    /// The tag that tells clients apart comes from a key that is replaced every day and never
    /// stored, so nothing can link an install back to an address afterwards.
    pub fn count(&self, item: i64, client: &IpKey) {
        let tag = {
            let mut day = self.day.lock().unwrap_or_else(PoisonError::into_inner);
            if day.day != today() {
                *day = DayKey {
                    day: today(),
                    key: rand::random(),
                };
                self.seen.invalidate_all();
            }
            let item = item.to_le_bytes();
            let Some(full) =
                crate::crypto::hmac_sha256(&day.key, &[&item, client.to_string().as_bytes()])
            else {
                return;
            };
            u64::from_le_bytes([
                full[0], full[1], full[2], full[3], full[4], full[5], full[6], full[7],
            ])
        };
        if self.seen.entry(tag).or_insert(()).is_fresh() {
            *self
                .pending
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .entry(item)
                .or_insert(0) += 1;
        }
    }

    /// Writes the counted installs. What can't be written is kept for the next round.
    pub async fn flush(&self, pool: &SqlitePool) {
        let batch =
            std::mem::take(&mut *self.pending.lock().unwrap_or_else(PoisonError::into_inner));
        for (item, n) in batch {
            let written = sqlx::query("UPDATE items SET installs = installs + ?1 WHERE id = ?2")
                .bind(n)
                .bind(item)
                .execute(pool)
                .await;
            if let Err(e) = written {
                tracing::error!(error = %e, "writing installs failed");
                *self
                    .pending
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .entry(item)
                    .or_insert(0) += n;
            }
        }
    }
}

impl Default for Installs {
    fn default() -> Self {
        Self::new()
    }
}
