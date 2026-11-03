//! Where an API key comes from: the environment variable named in the settings, or the system
//! keychain. A key is never printed and never written to the settings file.

use crate::config::{Config, ImpConfig};
use crate::{CliError, Result};

const SERVICE: &str = "imp";

/// A key and where it was found. `Debug` hides the key.
pub struct FoundKey {
    pub key: String,
    pub source: KeySource,
}

impl std::fmt::Debug for FoundKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FoundKey")
            .field("key", &"<hidden>")
            .field("source", &self.source)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeySource {
    Environment(String),
    Keychain,
}

impl KeySource {
    pub fn describe(&self) -> String {
        match self {
            Self::Environment(var) => format!("the environment variable {var}"),
            Self::Keychain => "the system keychain".to_string(),
        }
    }
}

/// The name of the environment variable that holds the key for `imp`.
pub fn env_name<'a>(config: &'a Config, imp: &'a ImpConfig) -> &'a str {
    imp.api_key_env.as_deref().unwrap_or(&config.api_key_env)
}

/// Finds a key: the environment first, then the keychain. `env` and `keychain` are given as
/// functions so tests can stand in for the real ones. Many services (a local model, for one) need no key.
pub fn find(
    config: &Config,
    imp_name: &str,
    imp: &ImpConfig,
    env: impl Fn(&str) -> Option<String>,
    keychain: impl Fn(&str) -> Option<String>,
) -> Option<FoundKey> {
    let var = env_name(config, imp);
    if let Some(key) = env(var)
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
    {
        return Some(FoundKey {
            key,
            source: KeySource::Environment(var.to_string()),
        });
    }
    keychain(imp_name).map(|key| FoundKey {
        key,
        source: KeySource::Keychain,
    })
}

pub fn real_env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

pub fn real_keychain(imp_name: &str) -> Option<String> {
    keyring::Entry::new(SERVICE, imp_name)
        .ok()?
        .get_password()
        .ok()
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

pub fn save_to_keychain(imp_name: &str, key: &str) -> Result<()> {
    keyring::Entry::new(SERVICE, imp_name)
        .and_then(|e| e.set_password(key))
        .map_err(|e| CliError(format!("Could not save to the system keychain: {e}")))
}

pub fn remove_from_keychain(imp_name: &str) -> Result<()> {
    match keyring::Entry::new(SERVICE, imp_name).and_then(|e| e.delete_credential()) {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(CliError(format!(
            "Could not remove it from the system keychain: {e}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (Config, ImpConfig) {
        let config = Config::default();
        let imp = ImpConfig::new(String::new(), String::new(), String::new());
        (config, imp)
    }

    #[test]
    fn environment_wins_over_keychain() {
        let (c, i) = setup();
        let found = find(
            &c,
            "pip",
            &i,
            |n| (n == "IMP_API_KEY").then(|| " sk-env \n".to_string()),
            |_| Some("sk-chain".into()),
        )
        .unwrap();
        assert_eq!(found.key, "sk-env");
        assert_eq!(found.source, KeySource::Environment("IMP_API_KEY".into()));
    }

    #[test]
    fn falls_back_to_keychain_then_nothing() {
        let (c, i) = setup();
        assert_eq!(
            find(
                &c,
                "pip",
                &i,
                |_| Some("  ".into()),
                |_| Some("sk-chain".into())
            )
            .unwrap()
            .source,
            KeySource::Keychain
        );
        assert!(find(&c, "pip", &i, |_| None, |_| None).is_none());
    }

    #[test]
    fn an_imp_can_name_its_own_variable() {
        let (c, mut i) = setup();
        i.api_key_env = Some("OTHER".into());
        let found = find(
            &c,
            "pip",
            &i,
            |n| (n == "OTHER").then(|| "k".to_string()),
            |_| None,
        )
        .unwrap();
        assert_eq!(found.source, KeySource::Environment("OTHER".into()));
    }

    #[test]
    fn debug_hides_the_key() {
        let found = FoundKey {
            key: "sk-secret".into(),
            source: KeySource::Keychain,
        };
        assert!(!format!("{found:?}").contains("sk-secret"));
    }
}
