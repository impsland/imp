//! Keyed rate limits (governor), one bucket per client key.

use std::hash::Hash;
use std::time::Duration;

use governor::clock::{Clock, DefaultClock};
use governor::{DefaultKeyedRateLimiter, Quota, RateLimiter};

/// `burst` actions per `period` for each key, replenished evenly.
pub struct KeyedLimiter<K: Hash + Eq + Clone> {
    inner: DefaultKeyedRateLimiter<K>,
    clock: DefaultClock,
}

impl<K: Hash + Eq + Clone> KeyedLimiter<K> {
    /// A zero `burst` or `period` is treated as one.
    pub fn new(burst: u32, period: Duration) -> Self {
        let burst = burst.max(1);
        let spacing = (period / burst).max(Duration::from_millis(1));
        let quota = Quota::with_period(spacing)
            .unwrap_or_else(|| Quota::per_second(std::num::NonZeroU32::MIN))
            .allow_burst(std::num::NonZeroU32::new(burst).unwrap_or(std::num::NonZeroU32::MIN));
        Self {
            inner: RateLimiter::keyed(quota),
            clock: DefaultClock::default(),
        }
    }

    pub fn per_minute(n: u32) -> Self {
        Self::new(n, Duration::from_secs(60))
    }

    pub fn per_hour(n: u32) -> Self {
        Self::new(n, Duration::from_secs(3600))
    }

    pub fn per_day(n: u32) -> Self {
        Self::new(n, Duration::from_secs(86_400))
    }

    /// Takes one action for `key`, or says how long to wait.
    pub fn check(&self, key: &K) -> Result<(), Duration> {
        self.inner
            .check_key(key)
            .map_err(|not_until| not_until.wait_time_from(self.clock.now()))
    }

    /// Forgets keys that are back to a full bucket. Call now and then.
    pub fn sweep(&self) {
        self.inner.retain_recent();
        self.inner.shrink_to_fit();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_a_burst_then_says_how_long() {
        let limiter = KeyedLimiter::<u8>::per_minute(2);
        assert!(limiter.check(&1).is_ok());
        assert!(limiter.check(&1).is_ok());
        let wait = limiter.check(&1).expect_err("third is limited");
        assert!(wait > Duration::ZERO && wait <= Duration::from_secs(30));
        assert!(limiter.check(&2).is_ok());
    }
}
