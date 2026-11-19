//! Local encryption: AES-256-GCM with a random 96-bit nonce per seal.
//!
//! Format: `b"CMV1" || nonce(12) || ciphertext+tag`. The key (32 bytes) lives in
//! the platform keystore (Android Keystore / iOS Keychain), never on disk.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Key, Nonce};

use crate::{random_bytes, CryptoError, Result};

const MAGIC: &[u8; 4] = b"CMV1";
pub const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;

fn cipher(key: &[u8]) -> Result<Aes256Gcm> {
    if key.len() != KEY_LEN {
        return Err(CryptoError::InvalidInput(
            "vault key must be 32 bytes".into(),
        ));
    }
    Ok(Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key)))
}

/// Encrypts `plaintext`. `context` is authenticated but not encrypted (e.g. a
/// file name), so a sealed blob cannot be swapped for another one.
pub fn seal(key: &[u8], context: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let nonce = random_bytes(NONCE_LEN)?;
    let ct = cipher(key)?
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: context,
            },
        )
        .map_err(|_| CryptoError::Decryption)?;
    let mut out = Vec::with_capacity(4 + NONCE_LEN + ct.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Decrypts a blob produced by [`seal`] with the same key and context.
pub fn open(key: &[u8], context: &[u8], sealed: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < 4 + NONCE_LEN + 16 || &sealed[..4] != MAGIC {
        return Err(CryptoError::InvalidInput("not a vault blob".into()));
    }
    let (nonce, ct) = sealed[4..].split_at(NONCE_LEN);
    cipher(key)?
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: ct,
                aad: context,
            },
        )
        .map_err(|_| CryptoError::Decryption)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_tamper() {
        let key = random_bytes(32).unwrap();
        let blob = seal(&key, b"ctx", b"segredo").unwrap();
        assert_eq!(open(&key, b"ctx", &blob).unwrap(), b"segredo");
        assert!(open(&key, b"outro", &blob).is_err());
        assert!(open(&random_bytes(32).unwrap(), b"ctx", &blob).is_err());
        let mut bad = blob.clone();
        *bad.last_mut().unwrap() ^= 1;
        assert!(open(&key, b"ctx", &bad).is_err());
        assert_ne!(
            seal(&key, b"ctx", b"segredo").unwrap(),
            blob,
            "nonce must be random"
        );
        assert!(seal(&[0u8; 16], b"", b"x").is_err());
    }
}
