#![forbid(unsafe_code)]

use std::process::ExitCode;

use hop::Config;
use imp_shared::{config, health, shutdown, telemetry};
use tokio::net::TcpListener;

/// musl's allocator is slow under many threads, so the static Alpine build uses mimalloc.
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[tokio::main]
async fn main() -> ExitCode {
    telemetry::init(telemetry::wants_json(
        config::env_opt("HOP_LOG_FORMAT").as_deref(),
    ));
    let config = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("{e}");
            return ExitCode::FAILURE;
        }
    };
    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        return match health::local_target(&config.addr.to_string()) {
            Some(target) => health::tcp(target).await,
            None => ExitCode::FAILURE,
        };
    }
    let listener = match TcpListener::bind(config.addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(addr = %config.addr, "cannot listen: {e}");
            return ExitCode::FAILURE;
        }
    };
    tracing::info!(addr = %config.addr, "hop listening");
    hop::run(listener, config, shutdown::signal()).await;
    tracing::info!("hop stopped");
    ExitCode::SUCCESS
}
