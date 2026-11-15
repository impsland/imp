//! Settings from environment variables.

use std::str::FromStr;

/// A variable that is missing, or whose value does not parse or fails a check.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{0} is required")]
    Missing(&'static str),
    #[error("{name} is not valid: {reason}")]
    Invalid { name: &'static str, reason: String },
}

/// The value of `name`, or `None` when it is unset, empty or only whitespace.
pub fn env_opt(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

/// The value of `name`, or `ConfigError::Missing` when it is unset, empty or only whitespace.
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

#[cfg(test)]
mod tests {
    use super::*;

    // Distinct variable names: tests share one process environment.
    #[test]
    fn unset_empty_and_bad_values() {
        assert_eq!(env_parse("IMP_TEST_UNSET_X", 7u32).unwrap(), 7);
        assert!(matches!(
            env_required("IMP_TEST_UNSET_Y"),
            Err(ConfigError::Missing("IMP_TEST_UNSET_Y"))
        ));
    }
}
