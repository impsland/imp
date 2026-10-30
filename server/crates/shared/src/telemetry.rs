//! Logging.

use tracing_subscriber::EnvFilter;

/// Logs to stderr, as JSON lines or plain text. `RUST_LOG` overrides the default level (info).
pub fn init(json: bool) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr);
    let result = if json {
        builder.json().try_init()
    } else {
        builder.try_init()
    };
    drop(result);
}

/// Whether `value` (usually `DEN_LOG_FORMAT`) asks for JSON lines.
pub fn wants_json(value: Option<&str>) -> bool {
    value.is_some_and(|v| v.eq_ignore_ascii_case("json"))
}
