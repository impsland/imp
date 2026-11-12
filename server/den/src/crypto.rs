use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};

/// HMAC-SHA256 over the concatenation of `parts`. `None` only if the key were unusable, which
/// HMAC never says for a byte string.
pub fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> Option<[u8; 32]> {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).ok()?;
    for part in parts {
        mac.update(part);
    }
    Some(mac.finalize().into_bytes().into())
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}
