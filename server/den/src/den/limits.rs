//! Rate limits of the Den, one limiter per kind of request.

use super::*;

pub(super) struct Limits {
    pub(super) reads: KeyedLimiter<IpKey>,
    pub(super) challenges: KeyedLimiter<IpKey>,
    /// Posts of the sign-in page.
    pub(super) attempts: KeyedLimiter<IpKey>,
    pub(super) accounts: KeyedLimiter<IpKey>,
    pub(super) registrations: KeyedLimiter<IpKey>,
    pub(super) tokens: KeyedLimiter<IpKey>,
    pub(super) reports: KeyedLimiter<IpKey>,
    pub(super) installs: KeyedLimiter<IpKey>,
    pub(super) writes_by_ip: KeyedLimiter<IpKey>,
    pub(super) writes_by_account: KeyedLimiter<String>,
}

impl Limits {
    pub(super) fn new() -> Self {
        Self {
            reads: KeyedLimiter::per_minute(240),
            challenges: KeyedLimiter::per_minute(20),
            attempts: KeyedLimiter::per_minute(20),
            accounts: KeyedLimiter::per_day(3),
            registrations: KeyedLimiter::per_hour(20),
            tokens: KeyedLimiter::per_hour(60),
            reports: KeyedLimiter::per_hour(10),
            installs: KeyedLimiter::per_hour(120),
            writes_by_ip: KeyedLimiter::per_hour(30),
            writes_by_account: KeyedLimiter::per_hour(30),
        }
    }

    pub(super) fn sweep(&self) {
        self.reads.sweep();
        self.challenges.sweep();
        self.attempts.sweep();
        self.accounts.sweep();
        self.registrations.sweep();
        self.tokens.sweep();
        self.reports.sweep();
        self.installs.sweep();
        self.writes_by_ip.sweep();
        self.writes_by_account.sweep();
    }
}

pub(super) fn gate<K: std::hash::Hash + Eq + Clone>(
    limiter: &KeyedLimiter<K>,
    key: &K,
) -> Result<(), Error> {
    limiter.check(key).map_err(Error::RateLimited)
}
