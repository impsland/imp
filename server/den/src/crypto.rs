use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};

/// HMAC-SHA256 over the concatenation of `parts`. Returns `None` only if the MAC cannot be keyed,
/// which HMAC never reports for a byte slice of any length.
pub fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> Option<[u8; 32]> {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).ok()?;
    for part in parts {
        mac.update(part);
    }
    Some(mac.finalize().into_bytes().into())
}

/// The lowercase hex SHA-256 digest of `data`.
pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}
