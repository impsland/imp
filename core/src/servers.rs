//! The two server addresses a person can set: the Den (a URL) and the Hop (`host:port`). Each is
//! checked here, so every app gives the same answer and the same readable sentence. Nothing here
//! reaches the network. The vectors are `spec/fixtures/server-addresses.json`.

use crate::link::hop::{HopAddress, is_host};

/// The Den the Imp project runs. The app's default choice.
pub const DEFAULT_DEN: &str = "https://den.imps.land";
/// The Hop the Imp project runs. The app's default choice.
pub const DEFAULT_HOP: &str = "hop.imps.land:4677";
/// The Den that `imp serve` runs on this computer.
pub const LOCAL_DEN: &str = "http://localhost:8080";
/// The Hop that `imp serve` runs on this computer.
pub const LOCAL_HOP: &str = "localhost:4677";
/// The path a Den answers 200 on when it is up.
pub const DEN_HEALTH_PATH: &str = "/healthz";
/// The port a Hop listens on unless the address says another one.
pub const HOP_PORT: u16 = 4677;

/// Why an address was refused. The text is what a person reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AddressError {
    #[error("Use an address like den.example.com or https://den.example.com.")]
    DenForm,
    #[error("The Den address must start with http:// or https://.")]
    DenScheme,
    #[error("Use an address like hop.example.com or hop.example.com:4677.")]
    HopForm,
    #[error("Use just the address, with no path after it.")]
    Path,
    #[error("That is not a valid host name. Use a name such as example.com.")]
    Host,
    #[error("The port must be a number from 1 to 65535.")]
    Port,
}

/// A Den address that passed the checks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DenAddress {
    /// `http` or `https`.
    pub scheme: String,
    pub host: String,
    pub port: Option<u16>,
}

impl DenAddress {
    /// The base URL, such as `https://den.example.com`, with no path and no final slash.
    pub fn url(&self) -> String {
        match self.port {
            Some(port) => format!("{}://{}:{port}", self.scheme, self.host),
            None => format!("{}://{}", self.scheme, self.host),
        }
    }

    /// The page an app asks to learn whether the Den is up. It answers 200 only when the Den can reach its store.
    pub fn health_url(&self) -> String {
        format!("{}{DEN_HEALTH_PATH}", self.url())
    }
}

/// Splits `host` or `host:port` (`form` is the answer for a missing host). A port that is not plain digits from 1 to 65535 is refused.
fn host_and_port(text: &str, form: AddressError) -> Result<(String, Option<u16>), AddressError> {
    let (host, port) = match text.rsplit_once(':') {
        Some((host, digits)) => {
            let port = (!digits.is_empty()
                && digits.len() <= 5
                && digits.bytes().all(|b| b.is_ascii_digit()))
            .then(|| digits.parse::<u16>().ok())
            .flatten()
            .filter(|p| *p > 0)
            .ok_or(AddressError::Port)?;
            (host, Some(port))
        }
        None => (text, None),
    };
    if host.is_empty() {
        return Err(form);
    }
    let host = host.to_lowercase();
    if is_host(&host) {
        Ok((host, port))
    } else {
        Err(AddressError::Host)
    }
}

/// Cuts `text` at the path, the query or the fragment: (the part before, what follows).
fn split_tail(text: &str) -> (&str, &str) {
    text.split_at(text.find(['/', '?', '#']).unwrap_or(text.len()))
}

/// Reads the Den address. Empty text is no Den (`Ok(None)`). A bare host name means `https`.
pub fn check_den(text: &str) -> Result<Option<DenAddress>, AddressError> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    if text.contains(char::is_whitespace) {
        return Err(AddressError::DenForm);
    }
    let (scheme, rest) = match text.split_once("://") {
        Some((scheme, rest)) => (scheme.to_lowercase(), rest),
        None => ("https".to_owned(), text),
    };
    if scheme != "http" && scheme != "https" {
        return Err(AddressError::DenScheme);
    }
    let (authority, tail) = split_tail(rest);
    if tail.starts_with(['?', '#']) || authority.contains('@') {
        return Err(AddressError::DenForm);
    }
    if !tail.is_empty() && tail != "/" {
        return Err(AddressError::Path);
    }
    let (host, port) = host_and_port(authority, AddressError::DenForm)?;
    Ok(Some(DenAddress { scheme, host, port }))
}

/// Reads the Hop address, `host:port`. A host with no port gets `HOP_PORT`. Empty text is no Hop.
pub fn check_hop(text: &str) -> Result<Option<HopAddress>, AddressError> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    if text.contains(char::is_whitespace) || text.contains("://") || text.contains('@') {
        return Err(AddressError::HopForm);
    }
    let (authority, tail) = split_tail(text);
    if !tail.is_empty() {
        return Err(AddressError::Path);
    }
    let (host, port) = host_and_port(authority, AddressError::HopForm)?;
    Ok(Some(HopAddress {
        host,
        port: port.unwrap_or(HOP_PORT),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn the_den_is_probed_at_its_health_path() {
        let den = |text: &str| check_den(text).unwrap().unwrap();
        assert_eq!(
            den("den.example.com").health_url(),
            "https://den.example.com/healthz"
        );
        assert_eq!(
            den("http://localhost:8080/").health_url(),
            "http://localhost:8080/healthz"
        );
    }

    fn vectors() -> Value {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../spec/fixtures/server-addresses.json"
        )))
        .unwrap()
    }

    fn answer<T>(
        result: Result<Option<T>, AddressError>,
        show: impl Fn(&T) -> String,
    ) -> (String, Option<String>) {
        match result {
            Ok(Some(value)) => (show(&value), None),
            Ok(None) => (String::new(), None),
            Err(e) => (String::new(), Some(e.to_string())),
        }
    }

    #[test]
    fn the_den_vectors_hold() {
        let all = vectors();
        let cases = all["den"].as_array().unwrap();
        assert!(cases.len() >= 20);
        for case in cases {
            let input = case["input"].as_str().unwrap();
            let got = answer(check_den(input), DenAddress::url);
            let want = (
                case["address"].as_str().unwrap().to_owned(),
                case["error"].as_str().map(str::to_owned),
            );
            assert_eq!(got, want, "den {input:?}");
        }
    }

    #[test]
    fn the_hop_vectors_hold() {
        let all = vectors();
        let cases = all["hop"].as_array().unwrap();
        assert!(cases.len() >= 20);
        for case in cases {
            let input = case["input"].as_str().unwrap();
            let got = answer(check_hop(input), HopAddress::text);
            let want = (
                case["address"].as_str().unwrap().to_owned(),
                case["error"].as_str().map(str::to_owned),
            );
            assert_eq!(got, want, "hop {input:?}");
        }
    }

    #[test]
    fn the_defaults_and_the_local_choices_are_valid_addresses() {
        assert_eq!(check_den(DEFAULT_DEN).unwrap().unwrap().url(), DEFAULT_DEN);
        assert_eq!(check_den(LOCAL_DEN).unwrap().unwrap().url(), LOCAL_DEN);
        assert_eq!(check_hop(DEFAULT_HOP).unwrap().unwrap().text(), DEFAULT_HOP);
        assert_eq!(check_hop(LOCAL_HOP).unwrap().unwrap().text(), LOCAL_HOP);
    }
}
