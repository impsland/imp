use std::str::FromStr;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};

/// Opens the database (`:memory:` for tests) and applies the embedded migrations.
pub async fn open(path: &str) -> Result<SqlitePool, sqlx::Error> {
    let memory = path == ":memory:";
    let options = if memory {
        SqliteConnectOptions::from_str("sqlite::memory:")?
    } else {
        SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
    };
    let options = options
        .foreign_keys(true)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5));
    let pool = SqlitePoolOptions::new()
        .max_connections(if memory { 1 } else { 8 })
        .min_connections(u32::from(memory))
        .idle_timeout(if memory {
            None
        } else {
            Some(Duration::from_secs(300))
        })
        .max_lifetime(None)
        .connect_with(options)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}
