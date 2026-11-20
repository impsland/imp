//! Redirect URIs of OAuth clients (RFC 8252): what may be registered, and when a presented one matches.

const MAX_LEN: usize = 2000;

/// What is wrong with `uri` as a redirect URI, if anything.
///
/// Allowed: `https://` URLs; `http://` only on the loopback names `127.0.0.1`, `[::1]` and `localhost`
/// (with any port), and a private-use scheme with a dot in it, such as `app.imp:/oauth`.
pub fn problem(uri: &str) -> Option<&'static str> {
    if uri.len() > MAX_LEN {
        return Some("is too long");
    }
    if uri
        .chars()
        .any(|c| c.is_control() || c.is_whitespace() || c == '\\' || c == '#')
    {
        return Some("has spaces, control characters, a backslash or a fragment");
    }
    let Some((scheme, rest)) = uri.split_once(':') else {
        return Some("needs a scheme");
    };
    let scheme_ok = scheme.starts_with(|c: char| c.is_ascii_lowercase())
        && scheme.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'+' | b'-' | b'.')
        });
    if !scheme_ok {
        return Some("has a scheme in lowercase letters, digits and + - .");
    }
    match scheme {
        "https" => {
            let Some(after) = rest.strip_prefix("//") else {
                return Some("is not a URL");
            };
            let authority = after.split(['/', '?']).next().unwrap_or_default();
            if authority.is_empty() || authority.contains('@') {
                Some("needs a host and no user name")
            } else {
                None
            }
        }
        "http" => loopback(uri)
            .is_none()
            .then_some("may use http only on 127.0.0.1, [::1] or localhost"),
        _ if scheme.contains('.') => None,
        _ => Some("must be https, loopback http, or a private-use scheme with a dot in it"),
    }
}

/// `(host, path and query)` of a loopback `http://` URI, whatever its port.
fn loopback(uri: &str) -> Option<(&str, &str)> {
    let rest = uri.strip_prefix("http://")?;
    let end = rest.find(['/', '?']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !authority.ends_with(']') => (host, Some(port)),
        _ => (authority, None),
    };
    if let Some(port) = port
        && !port.parse::<u16>().is_ok_and(|p| p > 0)
    {
        return None;
    }
    matches!(host, "127.0.0.1" | "[::1]" | "localhost").then_some((host, tail))
}

/// Whether the redirect URI `presented` is the registered `registered`: an exact match, except that
/// the port of a loopback URI may differ.
pub fn same(registered: &str, presented: &str) -> bool {
    if registered == presented {
        return true;
    }
    matches!((loopback(registered), loopback(presented)), (Some(a), Some(b)) if a == b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_may_be_registered() {
        for ok in [
            "https://app.example/cb",
            "https://app.example:8443/cb?x=1",
            "http://127.0.0.1:53211/oauth",
            "http://localhost/cb",
            "http://[::1]:9/cb",
            "app.imp:/oauth",
            "app.imp://oauth",
            "com.example.app:/cb",
        ] {
            assert!(problem(ok).is_none(), "{ok}");
        }
        for bad in [
            "http://example.com/cb",
            "http://127.0.0.1.evil.com/cb",
            "http://localhost:0/cb",
            "http://localhost:99999/cb",
            "https://user@example.com/cb",
            "https:///cb",
            "https://example.com/cb#frag",
            "javascript:alert(1)",
            "myapp:/cb",
            "ftp://example.com",
            "/cb",
            "app.imp:/o auth",
            "App.imp:/cb",
            "",
        ] {
            assert!(problem(bad).is_some(), "{bad}");
        }
        assert!(problem(&format!("https://a.example/{}", "x".repeat(2000))).is_some());
    }

    #[test]
    fn matching_is_exact_except_the_port_of_loopback() {
        assert!(same("https://a.example/cb", "https://a.example/cb"));
        assert!(!same("https://a.example/cb", "https://a.example/cb2"));
        assert!(!same("https://a.example/cb", "https://a.example:444/cb"));
        assert!(same(
            "http://127.0.0.1:1/oauth",
            "http://127.0.0.1:60000/oauth"
        ));
        assert!(same(
            "http://127.0.0.1/oauth",
            "http://127.0.0.1:60000/oauth"
        ));
        assert!(!same(
            "http://127.0.0.1:1/oauth",
            "http://127.0.0.1:2/other"
        ));
        assert!(!same(
            "http://127.0.0.1:1/oauth",
            "http://localhost:1/oauth"
        ));
        assert!(same("app.imp:/oauth", "app.imp:/oauth"));
        assert!(!same("app.imp:/oauth", "app.imp:/oauth2"));
    }
}
