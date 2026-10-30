//! Who may connect: per-IP and overall caps, and new connections per minute.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use imp_shared::ip::IpKey;
use imp_shared::limit::KeyedLimiter;

use crate::Config;

pub struct Limits {
    open: Mutex<Open>,
    per_ip: usize,
    max: usize,
    rate: KeyedLimiter<IpKey>,
}

#[derive(Default)]
struct Open {
    total: usize,
    by_ip: HashMap<IpKey, usize>,
}

/// One admitted connection. Dropping it frees the slot.
pub struct ConnGuard {
    limits: Arc<Limits>,
    ip: IpKey,
}

impl Limits {
    pub fn new(config: &Config) -> Arc<Self> {
        Arc::new(Self {
            open: Mutex::default(),
            per_ip: config.per_ip_connections,
            max: config.max_connections,
            rate: KeyedLimiter::new(config.per_ip_per_minute, Duration::from_secs(60)),
        })
    }

    /// A slot for a new connection from `ip`, or `None` when a limit is hit.
    pub fn admit(self: &Arc<Self>, ip: IpKey) -> Option<ConnGuard> {
        {
            let mut open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
            let mine = open.by_ip.get(&ip).copied().unwrap_or(0);
            if open.total >= self.max || mine >= self.per_ip {
                return None;
            }
            if self.rate.check(&ip).is_err() {
                return None;
            }
            open.total += 1;
            *open.by_ip.entry(ip).or_insert(0) += 1;
        }
        Some(ConnGuard {
            limits: Arc::clone(self),
            ip,
        })
    }

    pub fn sweep(&self) {
        self.rate.sweep();
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        let mut open = self
            .limits
            .open
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        open.total = open.total.saturating_sub(1);
        if let Some(n) = open.by_ip.get_mut(&self.ip) {
            *n -= 1;
            if *n == 0 {
                open.by_ip.remove(&self.ip);
            }
        }
    }
}
