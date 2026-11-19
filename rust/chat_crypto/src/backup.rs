//! Two-share encrypted backups (roadmap, section 3.2).
//!
//! key = HKDF-SHA256(ikm = Argon2id(recovery_code, salt) || server_share,
//!                   info = "chatminusis-backup-v1")
//! blob = "CMBK" || version(1) || salt(16) || m_kib(u32) || t(u32) || p(u32) || vault-sealed payload
//!
//! Opening needs the recovery code (only the user has it) AND the server share
//! (only delivered to the authenticated owner). Neither alone helps.

use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{random_bytes, vault, CryptoError, Result};

const MAGIC: &[u8; 4] = b"CMBK";
const VERSION: u8 = 1;
const SALT_LEN: usize = 16;
const HEADER_LEN: usize = 4 + 1 + SALT_LEN + 12;
const INFO: &[u8] = b"chatminusis-backup-v1";
pub const SERVER_SHARE_LEN: usize = 32;

/// Argon2id cost. 64 MiB / 3 passes: slow enough to make guessing expensive,
/// fast enough for a phone (< ~1 s).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KdfParams {
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

pub const DEFAULT_PARAMS: KdfParams = KdfParams {
    memory_kib: 64 * 1024,
    iterations: 3,
    parallelism: 1,
};

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32

/// 260-bit recovery code: 52 Crockford base32 characters, shown in groups of 4.
pub fn generate_recovery_code() -> Result<String> {
    let bytes = random_bytes(33)?;
    let bit = |i: usize| (bytes[i / 8] >> (7 - i % 8)) & 1;
    let symbols: Vec<char> = (0..52)
        .map(|s| {
            let v = (0..5).fold(0usize, |acc, k| (acc << 1) | bit(s * 5 + k) as usize);
            ALPHABET[v] as char
        })
        .collect();
    Ok(symbols
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("-"))
}

/// Canonical form: uppercase, no separators/spaces, Crockford aliases (O->0, I/L->1).
pub fn normalize_recovery_code(code: &str) -> Result<String> {
    let s: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect();
    if s.len() != 52 || !s.bytes().all(|b| ALPHABET.contains(&b)) {
        return Err(CryptoError::InvalidInput("invalid recovery code".into()));
    }
    Ok(s)
}

fn derive_key(
    code: &str,
    server_share: &[u8],
    salt: &[u8],
    p: KdfParams,
) -> Result<Zeroizing<Vec<u8>>> {
    if server_share.len() != SERVER_SHARE_LEN {
        return Err(CryptoError::InvalidInput(
            "server share must be 32 bytes".into(),
        ));
    }
    let code = normalize_recovery_code(code)?;
    let params = Params::new(p.memory_kib, p.iterations, p.parallelism, Some(32))
        .map_err(|e| CryptoError::InvalidInput(e.to_string()))?;
    let mut user_half = Zeroizing::new(vec![0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(code.as_bytes(), salt, &mut user_half)
        .map_err(|e| CryptoError::InvalidInput(e.to_string()))?;
    let mut ikm = Zeroizing::new(user_half.to_vec());
    ikm.extend_from_slice(server_share);
    let mut key = Zeroizing::new(vec![0u8; 32]);
    Hkdf::<Sha256>::new(Some(salt), &ikm)
        .expand(INFO, &mut key)
        .map_err(|_| CryptoError::InvalidInput("hkdf".into()))?;
    Ok(key)
}

pub fn seal_with_params(
    code: &str,
    server_share: &[u8],
    plaintext: &[u8],
    p: KdfParams,
) -> Result<Vec<u8>> {
    let salt = random_bytes(SALT_LEN)?;
    let key = derive_key(code, server_share, &salt, p)?;
    let mut header = Vec::with_capacity(HEADER_LEN);
    header.extend_from_slice(MAGIC);
    header.push(VERSION);
    header.extend_from_slice(&salt);
    header.extend_from_slice(&p.memory_kib.to_be_bytes());
    header.extend_from_slice(&p.iterations.to_be_bytes());
    header.extend_from_slice(&p.parallelism.to_be_bytes());
    // The header is authenticated as vault context: KDF params cannot be downgraded.
    let body = vault::seal(&key, &header, plaintext)?;
    header.extend_from_slice(&body);
    Ok(header)
}

/// Encrypts a backup with the default Argon2id cost.
pub fn seal(code: &str, server_share: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    seal_with_params(code, server_share, plaintext, DEFAULT_PARAMS)
}

pub fn open(code: &str, server_share: &[u8], blob: &[u8]) -> Result<Vec<u8>> {
    if blob.len() < HEADER_LEN || &blob[..4] != MAGIC || blob[4] != VERSION {
        return Err(CryptoError::InvalidInput("not a backup file".into()));
    }
    let (header, body) = blob.split_at(HEADER_LEN);
    let salt = &header[5..5 + SALT_LEN];
    let num = |i: usize| u32::from_be_bytes(header[i..i + 4].try_into().unwrap());
    let p = KdfParams {
        memory_kib: num(21),
        iterations: num(25),
        parallelism: num(29),
    };
    // Refuse absurd parameters from a crafted file (DoS) and weak ones (downgrade).
    if p.memory_kib < 19 * 1024
        || p.memory_kib > 1024 * 1024
        || p.iterations == 0
        || p.iterations > 20
        || p.parallelism == 0
        || p.parallelism > 8
    {
        return Err(CryptoError::InvalidInput(
            "unsupported backup parameters".into(),
        ));
    }
    let key = derive_key(code, server_share, salt, p)?;
    vault::open(&key, header, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAST: KdfParams = KdfParams {
        memory_kib: 19 * 1024,
        iterations: 1,
        parallelism: 1,
    };

    #[test]
    fn recovery_code_format() {
        let c = generate_recovery_code().unwrap();
        assert_eq!(c.len(), 52 + 12);
        assert_eq!(c.split('-').count(), 13);
        let n = normalize_recovery_code(&c.to_lowercase().replace('-', " ")).unwrap();
        assert_eq!(n.len(), 52);
        assert_ne!(c, generate_recovery_code().unwrap());
        assert!(normalize_recovery_code("curto").is_err());
    }

    #[test]
    fn needs_both_shares() {
        let code = generate_recovery_code().unwrap();
        let share = random_bytes(32).unwrap();
        let blob = seal_with_params(&code, &share, b"historico", FAST).unwrap();
        assert_eq!(open(&code, &share, &blob).unwrap(), b"historico");
        assert!(
            open(&code, &random_bytes(32).unwrap(), &blob).is_err(),
            "wrong server share"
        );
        assert!(
            open(&generate_recovery_code().unwrap(), &share, &blob).is_err(),
            "wrong code"
        );
        let mut bad = blob.clone();
        bad[25] ^= 1; // tamper with KDF params in the header
        assert!(open(&code, &share, &bad).is_err());
        assert!(open(&code, &share, b"lixo").is_err());
    }

    #[test]
    fn rejects_weak_or_absurd_params() {
        let code = generate_recovery_code().unwrap();
        let share = random_bytes(32).unwrap();
        let weak = KdfParams {
            memory_kib: 1024,
            iterations: 1,
            parallelism: 1,
        };
        let blob = seal_with_params(&code, &share, b"x", weak).unwrap();
        assert!(open(&code, &share, &blob).is_err());
    }
}
