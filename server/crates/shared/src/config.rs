//! Settings from environment variables.

use std::str::FromStr;

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{0} is required")]
    Missing(&'static str),
    #[error("{name} is not valid: {reason}")]
    Invalid { name: &'static str, reason: String },
}

/// The value of `name`, or `None` when it is unset or empty.
pub fn env_opt(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

pub fn env_required(name: &'static str) -> Result<String, ConfigError> {
    env_opt(name).ok_or(ConfigError::Missing(name))
}

/// The parsed value of `name`, or `default` when it is unset or empty.
pub fn env_parse<T>(name: &'static str, default: T) -> Result<T, ConfigError>
where
    T: FromStr,
    T::Err: std::fmt::Display,
{
    match env_opt(name) {
        None => Ok(default),
        Some(value) => value
            .trim()
            .parse()
            .map_err(|e: T::Err| ConfigError::Invalid {
                name,
                reason: e.to_string(),
            }),
    }
}
