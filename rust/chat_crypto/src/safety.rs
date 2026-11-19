//! Safety numbers: a 60-digit code both people see identically when their
//! identity keys are the ones they expect (same construction idea as Signal's
//! numeric fingerprints: iterated SHA-512 over version, key and identity).

use sha2::{Digest, Sha512};

const ITERATIONS: usize = 5200;
const VERSION: &[u8] = &[0, 0];

/// 30 digits derived from one person's identity and public signature key.
fn half(identity: &[u8], public_key: &[u8]) -> String {
    let mut hash = {
        let mut h = Sha512::new();
        h.update(VERSION);
        h.update(public_key);
        h.update(identity);
        h.finalize().to_vec()
    };
    for _ in 1..ITERATIONS {
        let mut h = Sha512::new();
        h.update(&hash);
        h.update(public_key);
        hash = h.finalize().to_vec();
    }
    // 6 chunks of 5 bytes -> 5 digits each.
    (0..6)
        .map(|i| {
            let c = &hash[i * 5..i * 5 + 5];
            let n = c.iter().fold(0u64, |acc, b| (acc << 8) | *b as u64) % 100_000;
            format!("{n:05}")
        })
        .collect()
}

/// Returns the safety number for a pair of people. It is symmetric: both sides
/// compute the same 60 digits, ordered by identity.
pub fn safety_number(
    my_identity: &[u8],
    my_key: &[u8],
    their_identity: &[u8],
    their_key: &[u8],
) -> String {
    let mine = half(my_identity, my_key);
    let theirs = half(their_identity, their_key);
    if my_identity <= their_identity {
        format!("{mine}{theirs}")
    } else {
        format!("{theirs}{mine}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symmetric_and_key_sensitive() {
        let a = safety_number(b"alice", b"ka", b"bob", b"kb");
        assert_eq!(a.len(), 60);
        assert!(a.chars().all(|c| c.is_ascii_digit()));
        assert_eq!(a, safety_number(b"bob", b"kb", b"alice", b"ka"));
        assert_ne!(a, safety_number(b"alice", b"ka", b"bob", b"OUTRA"));
    }
}
