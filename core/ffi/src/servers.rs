//! The Den and Hop addresses: the checks and the default choices. The rules stay in `imp-core`.

use imp_core::servers;

/// What checking a typed address gave. An empty `address` with no `message` is "no server". An
/// empty `address` with a `message` is a refusal, and the message says why in a sentence.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerCheck {
    /// The Den's base URL, or the Hop as `host:port`, in the form to keep.
    pub address: String,
    pub message: Option<String>,
}

impl ServerCheck {
    fn from<T>(
        result: Result<Option<T>, servers::AddressError>,
        show: impl Fn(&T) -> String,
    ) -> Self {
        match result {
            Ok(value) => Self {
                address: value.as_ref().map(show).unwrap_or_default(),
                message: None,
            },
            Err(e) => Self {
                address: String::new(),
                message: Some(e.to_string()),
            },
        }
    }
}

/// The addresses the server choices stand for.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerDefaults {
    pub den: String,
    pub hop: String,
    pub local_den: String,
    pub local_hop: String,
}

/// Checks what a person typed for the Den.
#[uniffi::export]
pub fn servers_check_den(text: String) -> ServerCheck {
    ServerCheck::from(servers::check_den(&text), servers::DenAddress::url)
}

/// The page that says whether the Den at a typed address is up, or nothing when the address is not a Den.
#[uniffi::export]
pub fn servers_den_health_url(text: String) -> Option<String> {
    servers::check_den(&text)
        .ok()
        .flatten()
        .map(|den| den.health_url())
}

/// Checks what a person typed for the Hop.
#[uniffi::export]
pub fn servers_check_hop(text: String) -> ServerCheck {
    ServerCheck::from(servers::check_hop(&text), imp_core::link::HopAddress::text)
}

/// The Imp project's servers and the ones `imp serve` runs on this computer.
#[uniffi::export]
pub fn servers_defaults() -> ServerDefaults {
    ServerDefaults {
        den: servers::DEFAULT_DEN.to_owned(),
        hop: servers::DEFAULT_HOP.to_owned(),
        local_den: servers::LOCAL_DEN.to_owned(),
        local_hop: servers::LOCAL_HOP.to_owned(),
    }
}
