//! E2EE core for the chat app.
//!
//! - [`client`]: MLS (RFC 9420) groups via OpenMLS, for 1:1 and group chats.
//! - [`vault`]: AES-256-GCM sealing of local data (MLS state, message history).
//! - [`safety`]: safety numbers users compare to verify each other.
//! - [`backup`]: two-share encrypted backups (recovery code + server share).
//!
//! The API deliberately uses only `Vec<u8>`, `String`, integers and plain
//! structs so it can be exposed to Dart with `flutter_rust_bridge`.

pub mod backup;
pub mod client;
pub mod safety;
pub mod vault;

#[cfg(feature = "pq-draft")]
pub use client::PQ_HYBRID_CIPHERSUITE;
pub use client::{
    AddMembersOutput, Client, CommitOutput, Expected, Incoming, MemberInfo, CIPHERSUITE,
};

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("unknown group")]
    UnknownGroup,
    #[error("member not found in group")]
    UnknownMember,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("decryption failed")]
    Decryption,
    #[error("mls error: {0}")]
    Mls(String),
}

pub type Result<T> = std::result::Result<T, CryptoError>;

pub(crate) fn mls<E: std::fmt::Debug>(e: E) -> CryptoError {
    CryptoError::Mls(format!("{e:?}"))
}

/// Cryptographically secure random bytes from the operating system.
pub fn random_bytes(len: usize) -> Result<Vec<u8>> {
    let mut out = vec![0u8; len];
    getrandom::getrandom(&mut out).map_err(|e| CryptoError::Mls(e.to_string()))?;
    Ok(out)
}
