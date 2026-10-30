#![forbid(unsafe_code)]

use std::process::ExitCode;

use den::config::Config;
use den::{Den, admin, db};
use imp_shared::config::{env_opt, env_parse};
use imp_shared::{health, shutdown, telemetry};
use tokio::net::TcpListener;
use tokio::sync::watch;

/// musl's allocator is slow under many threads, so the static Alpine build uses mimalloc.
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("serve") => serve().await,
        Some("healthcheck") => healthcheck().await,
        Some("admin") => {
            admin::run(
                &env_opt("DEN_DATABASE").unwrap_or_else(|| "den.db".to_owned()),
                &args[1..],
            )
            .await
        }
        Some(_) => {
            eprintln!("usage: den [serve | healthcheck | admin <command>]");
            ExitCode::from(2)
        }
    }
}

async fn healthcheck() -> ExitCode {
    let listen = env_parse("DEN_ADDR", "0.0.0.0:8080".to_owned()).unwrap_or_default();
    match health::local_target(&listen) {
        Some(target) => health::http(target).await,
        None => ExitCode::FAILURE,
    }
}

async fn serve() -> ExitCode {
    telemetry::init(telemetry::wants_json(env_opt("DEN_LOG_FORMAT").as_deref()));
    let config = match Config::from_env() {
        Ok(config) => config,
        Err(e) => {
            tracing::error!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let pool = match db::open(&config.database).await {
        Ok(pool) => pool,
        Err(e) => {
            tracing::error!(database = %config.database, "cannot open the database: {e}");
            return ExitCode::FAILURE;
        }
    };
    let listener = match TcpListener::bind(config.addr).await {
        Ok(listener) => listener,
        Err(e) => {
            tracing::error!(addr = %config.addr, "cannot listen: {e}");
            return ExitCode::FAILURE;
        }
    };
    tracing::info!(addr = %config.addr, public = %config.public.origin, "den listening");

    let den = Den::new(config, pool).await;
    let (stop, stopped) = watch::channel(false);
    let upkeep = tokio::spawn(std::sync::Arc::clone(&den).maintain(stopped));
    let app = den::router(den).into_make_service_with_connect_info::<std::net::SocketAddr>();
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown::signal())
        .await;
    let _ = stop.send(true);
    let _ = upkeep.await;
    match served {
        Ok(()) => {
            tracing::info!("den stopped");
            ExitCode::SUCCESS
        }
        Err(e) => {
            tracing::error!("server error: {e}");
            ExitCode::FAILURE
        }
    }
}
