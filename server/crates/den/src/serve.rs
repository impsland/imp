//! Runs a Den on a listener the caller already bound, so other programs (such as `imp serve`) can host one.
//!
//! The `den` program does its own start up from the environment and does not use this.

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::watch;

use crate::config::Config;
use crate::{Den, db};

/// Opens the database named in `config`, then serves on `listener` until `shutdown` completes.
/// The background upkeep is stopped and awaited before this returns.
pub async fn serve(
    config: Config,
    listener: TcpListener,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> Result<(), String> {
    let pool = db::open(&config.database)
        .await
        .map_err(|e| format!("cannot open the database {}: {e}", config.database))?;
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
