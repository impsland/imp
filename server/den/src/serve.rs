//! Runs a Den on a listener the caller already bound, so other programs (such as `imp serve`) can host one.
//!
//! The `den` program does its own startup from the environment and does not use this.

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::watch;

use crate::config::Config;
use crate::{Den, db};

/// Opens the database named in `config`, then serves on `listener` until `shutdown` completes.
/// It seeds the animation catalog first, as the `den` program does, so a hosted Den offers the
/// same `imp` items. The background upkeep is stopped and awaited before this returns.
pub async fn serve(
    config: Config,
    listener: TcpListener,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> Result<(), String> {
    let pool = db::open(&config.database)
        .await
        .map_err(|e| format!("cannot open the database {}: {e}", config.database))?;
    crate::catalog::seed(&pool)
        .await
        .map_err(|e| format!("cannot seed the animation catalog: {e}"))?;
    let den = Den::new(config, pool).await;
    let (stop, stopped) = watch::channel(false);
    let upkeep = tokio::spawn(Arc::clone(&den).maintain(stopped));
    let app = crate::router(den).into_make_service_with_connect_info::<SocketAddr>();
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await;
    let _ = stop.send(true);
    let _ = upkeep.await;
    served.map_err(|e| format!("server error: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PublicUrl;

    #[tokio::test]
    async fn a_hosted_den_has_the_animation_catalog() {
        let path = std::env::temp_dir().join(format!(
            "den-serve-{}.sqlite",
            hex::encode(rand::random::<[u8; 8]>())
        ));
        let name = path.to_string_lossy().into_owned();
        let config = Config {
            addr: "127.0.0.1:0".parse().unwrap(),
            database: name.clone(),
            secret: "a-test-secret-of-at-least-32-bytes!".to_owned(),
            public: PublicUrl::parse("https://den.test").unwrap(),
            trusted_proxies: "0.0.0.0/32".parse().unwrap(),
            altcha_cost: 10,
            json_logs: false,
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        serve(config, listener, async {}).await.unwrap();

        let pool = db::open(&name).await.unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM items WHERE handle = ?1")
            .bind(crate::catalog::HANDLE)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert!(count > 0, "serve seeds the catalog");
    }
}
