//! Multi-suite plumbing, exercised with the REAL draft hybrid post-quantum
//! suite (ML-KEM-768 + X25519). The app does not enable it yet; these tests
//! make sure the code is ready for the day it does.

use chat_crypto::{Client, CryptoError, Expected, Incoming, CIPHERSUITE, PQ_HYBRID_CIPHERSUITE};
use openmls::prelude::Ciphersuite;

const GROUP: &[u8] = b"pq-conversation";
const BOTH: &[Ciphersuite] = &[PQ_HYBRID_CIPHERSUITE, CIPHERSUITE];

fn classic(name: &str) -> Client {
    Client::new(name.as_bytes().to_vec()).unwrap()
}

fn hybrid(name: &str) -> Client {
    Client::with_ciphersuites(name.as_bytes().to_vec(), BOTH, PQ_HYBRID_CIPHERSUITE).unwrap()
}

fn add(c: &mut Client, group: &[u8], kps: Vec<Vec<u8>>) -> (Vec<u8>, Vec<u8>) {
    let out = c.add_members(group, kps).unwrap();
    c.merge_pending_commit(group).unwrap();
    (out.commit, out.welcome.unwrap())
}

#[test]
fn a_hybrid_post_quantum_group_works_end_to_end() {
    let mut alice = hybrid("alice");
    let mut bob = hybrid("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    assert_eq!(
        alice.group_ciphersuite(GROUP).unwrap(),
        PQ_HYBRID_CIPHERSUITE as u16
    );

    let kp = bob.generate_key_packages(1).unwrap().remove(0); // preferred = hybrid
    let (_, welcome) = add(&mut alice, GROUP, vec![kp]);
    assert_eq!(bob.join_group(welcome).unwrap(), GROUP);
    assert_eq!(
        bob.group_ciphersuite(GROUP).unwrap(),
        PQ_HYBRID_CIPHERSUITE as u16
    );

    let wire = alice
        .encrypt(GROUP, b"seguro contra computadores quanticos".to_vec())
        .unwrap();
    assert_eq!(
        bob.process(GROUP, wire, Expected::Application).unwrap(),
        Incoming::Application {
            sender: b"alice".to_vec(),
            plaintext: b"seguro contra computadores quanticos".to_vec()
        }
    );

    // Key rotation, removal and persistence also work with the hybrid suite.
    let rotation = alice.self_update(GROUP).unwrap();
    alice.merge_pending_commit(GROUP).unwrap();
    bob.process(GROUP, rotation.commit, Expected::Commit)
        .unwrap();
    let key = chat_crypto::random_bytes(32).unwrap();
    let state = bob.export_state(&key).unwrap();
    let mut bob =
        Client::restore_with_ciphersuites(&state, &key, BOTH, PQ_HYBRID_CIPHERSUITE).unwrap();
    let wire = alice
        .encrypt(GROUP, b"depois de restaurar".to_vec())
        .unwrap();
    assert!(bob.process(GROUP, wire, Expected::Application).is_ok());
}

#[test]
fn a_client_that_accepts_both_can_be_in_a_classic_and_a_hybrid_group() {
    let mut alice = hybrid("alice");
    let mut bob = hybrid("bob");

    alice.create_group(b"modern".to_vec()).unwrap();
    let (_, w) = add(
        &mut alice,
        b"modern",
        bob.generate_key_packages_for(PQ_HYBRID_CIPHERSUITE, 1)
            .unwrap(),
    );
    bob.join_group(w).unwrap();

    // Alice also has a classic group (a different Client created it with the baseline suite).
    let mut carol = classic("carol");
    carol.create_group(b"legacy".to_vec()).unwrap();
    let (_, w) = add(
        &mut carol,
        b"legacy",
        alice.generate_key_packages_for(CIPHERSUITE, 1).unwrap(),
    );
    alice.join_group(w).unwrap();

    assert_eq!(
        alice.group_ciphersuite(b"modern").unwrap(),
        PQ_HYBRID_CIPHERSUITE as u16
    );
    assert_eq!(
        alice.group_ciphersuite(b"legacy").unwrap(),
        CIPHERSUITE as u16
    );
    let wire = carol.encrypt(b"legacy", b"oi".to_vec()).unwrap();
    assert!(alice
        .process(b"legacy", wire, Expected::Application)
        .is_ok());
}

#[test]
fn a_key_package_of_the_wrong_suite_is_refused_before_its_crypto_runs() {
    let mut alice = hybrid("alice");
    alice.create_group(GROUP.to_vec()).unwrap(); // hybrid group
    let classic_kp = classic("bob").generate_key_package().unwrap();
    let err = alice.add_members(GROUP, vec![classic_kp]).unwrap_err();
    assert!(matches!(err, CryptoError::InvalidInput(_)), "{err:?}");

    // And the other way round: a classic group refuses hybrid key packages.
    let mut carol = classic("carol");
    carol.create_group(b"legacy".to_vec()).unwrap();
    let hybrid_kp = hybrid("dave").generate_key_packages(1).unwrap().remove(0);
    assert!(matches!(
        carol.add_members(b"legacy", vec![hybrid_kp]),
        Err(CryptoError::InvalidInput(_))
    ));
}

#[test]
fn a_client_refuses_a_welcome_for_a_suite_it_does_not_accept() {
    let mut alice = hybrid("alice");
    let mut bob = hybrid("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    let (_, welcome) = add(&mut alice, GROUP, bob.generate_key_packages(1).unwrap());

    let mut legacy_only = classic("bob"); // never opted in to the hybrid suite
    let err = legacy_only.join_group(welcome.clone()).unwrap_err();
    assert!(matches!(err, CryptoError::InvalidInput(_)), "{err:?}");
    assert!(!legacy_only.has_group(GROUP));
    assert!(
        bob.join_group(welcome).is_ok(),
        "the intended recipient is unaffected"
    );
}

#[test]
fn suite_configuration_is_validated() {
    // The preferred suite must be accepted.
    assert!(
        Client::with_ciphersuites(b"x".to_vec(), &[CIPHERSUITE], PQ_HYBRID_CIPHERSUITE).is_err()
    );
    // Suites with a different signature algorithm cannot share one identity key.
    assert!(Client::with_ciphersuites(
        b"x".to_vec(),
        &[
            CIPHERSUITE,
            Ciphersuite::MLS_128_DHKEMP256_AES128GCM_SHA256_P256
        ],
        CIPHERSUITE
    )
    .is_err());
    // Key packages can only be generated for accepted suites.
    assert!(classic("x")
        .generate_key_packages_for(PQ_HYBRID_CIPHERSUITE, 1)
        .is_err());
    assert_eq!(
        hybrid("x").accepted_ciphersuites(),
        vec![PQ_HYBRID_CIPHERSUITE as u16, CIPHERSUITE as u16]
    );
}
