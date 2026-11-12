//! Step 5: forwarding bytes both ways with bounded buffers, a bandwidth cap and an idle timeout.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::{Instant, sleep, sleep_until};

const CHUNK: usize = 16 * 1024;

/// A token bucket that holds up to one second of bytes.
struct Bucket {
    rate: f64,
    tokens: f64,
    last: Instant,
}

impl Bucket {
    fn new(bytes_per_second: u64) -> Self {
        let rate = bytes_per_second as f64;
        Self {
            rate,
            tokens: rate,
            last: Instant::now(),
        }
    }

    async fn take(&mut self, bytes: usize) {
        let now = Instant::now();
        self.tokens =
            (self.tokens + now.duration_since(self.last).as_secs_f64() * self.rate).min(self.rate);
        self.last = now;
        self.tokens -= bytes as f64;
        if self.tokens < 0.0 {
            sleep(Duration::from_secs_f64(-self.tokens / self.rate)).await;
        }
    }
}

/// Counts time from `start`, so "last activity" fits in an atomic.
struct Activity {
    start: Instant,
    last_ms: AtomicU64,
}

impl Activity {
    fn touch(&self) {
        let ms = u64::try_from(self.start.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.last_ms.store(ms, Ordering::Relaxed);
    }

    fn deadline(&self, idle: Duration) -> Instant {
        self.start + Duration::from_millis(self.last_ms.load(Ordering::Relaxed)) + idle
    }
}

async fn copy<R, W>(
    mut from: R,
    mut to: W,
    bytes_per_second: u64,
    activity: Arc<Activity>,
) -> io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut bucket = Bucket::new(bytes_per_second);
    let mut buf = vec![0u8; CHUNK];
    loop {
        let n = from.read(&mut buf).await?;
        if n == 0 {
            return to.shutdown().await;
        }
        bucket.take(n).await;
        to.write_all(&buf[..n]).await?;
        activity.touch();
    }
}

/// Runs until one side fails or both are done, the link is idle for `idle`, or `stop` completes.
pub async fn splice(
    a: TcpStream,
    b: TcpStream,
    bytes_per_second: u64,
    idle: Duration,
    stop: impl Future<Output = ()>,
) {
    let activity = Arc::new(Activity {
        start: Instant::now(),
        last_ms: AtomicU64::new(0),
    });
    let (a_read, a_write) = a.into_split();
    let (b_read, b_write) = b.into_split();
    let both = async {
        tokio::try_join!(
            copy(a_read, b_write, bytes_per_second, Arc::clone(&activity)),
            copy(b_read, a_write, bytes_per_second, Arc::clone(&activity)),
        )
    };
    let watchdog = async {
        loop {
            let deadline = activity.deadline(idle);
            if Instant::now() >= deadline {
                return;
            }
            sleep_until(deadline).await;
        }
    };
    tokio::select! {
        _ = both => {}
        () = watchdog => {}
        () = stop => {}
    }
}
