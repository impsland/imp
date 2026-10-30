use std::net::SocketAddr;

use imp_shared::config::{ConfigError, env_opt, env_parse, env_required};
use imp_shared::ip::TrustedProxies;

/// Where the Den lives on the internet, as set in `DEN_PUBLIC_URL`.
#[derive(Debug, Clone)]
pub struct PublicUrl {
    /// `https://den.example.org`, without a trailing slash.
    pub origin: String,
    /// `den.example.org` or `den.example.org:8443`.
    pub authority: String,
    /// `den.example.org`.
    pub host: String,
}

impl PublicUrl {
    pub fn parse(value: &str) -> Result<Self, ConfigError> {
        let invalid = |reason: &str| ConfigError::Invalid {
            name: "DEN_PUBLIC_URL",
            reason: reason.to_owned(),
        };
        let origin = value.trim().trim_end_matches('/');
        let authority = origin
            .strip_prefix("https://")
            .or_else(|| origin.strip_prefix("http://"))
            .ok_or_else(|| invalid("must start with https:// or http://"))?;
        if authority.is_empty() || authority.contains(['/', '?', '#', '@']) {
            return Err(invalid(
                "must be a bare origin such as https://den.example.org",
            ));
        }
        let host = match authority.rsplit_once(':') {
            Some((host, port)) if port.parse::<u16>().is_ok() => host,
            _ => authority,
        };
        Ok(Self {
            origin: origin.to_owned(),
            authority: authority.to_owned(),
            host: host.to_owned(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub addr: SocketAddr,
    pub database: String,
    pub secret: String,
    pub public: PublicUrl,
    pub trusted_proxies: TrustedProxies,
    pub altcha_cost: u32,
    pub json_logs: bool,
}

pub const MIN_SECRET_BYTES: usize = 32;
/// A phone solves this in about one to three seconds (see PROTOCOL.md).
pub const DEFAULT_ALTCHA_COST: u32 = 5_000;

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let secret = env_required("DEN_SECRET")?;
        if secret.len() < MIN_SECRET_BYTES {
            return Err(ConfigError::Invalid {
                name: "DEN_SECRET",
                reason: format!("needs at least {MIN_SECRET_BYTES} bytes"),
            });
        }
        let trusted_proxies = env_opt("DEN_TRUSTED_PROXIES")
            .map(|v| v.parse())
            .transpose()
            .map_err(|e: imp_shared::ip::CidrError| ConfigError::Invalid {
                name: "DEN_TRUSTED_PROXIES",
                reason: e.to_string(),
            })?
            .unwrap_or_default();
        let altcha_cost = env_parse("DEN_ALTCHA_COST", DEFAULT_ALTCHA_COST)?;
        if altcha_cost == 0 {
            return Err(ConfigError::Invalid {
                name: "DEN_ALTCHA_COST",
                reason: "must be at least 1".to_owned(),
            });
        }
        Ok(Self {
            addr: env_parse("DEN_ADDR", SocketAddr::from(([0, 0, 0, 0], 8080)))?,
            database: env_opt("DEN_DATABASE").unwrap_or_else(|| "den.db".to_owned()),
            secret,
            public: PublicUrl::parse(&env_required("DEN_PUBLIC_URL")?)?,
            trusted_proxies,
            altcha_cost,
            json_logs: imp_shared::telemetry::wants_json(env_opt("DEN_LOG_FORMAT").as_deref()),
        })
    }
}
