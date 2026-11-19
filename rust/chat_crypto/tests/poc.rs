//! Stage 0 proof of concept: the properties the chat needs, end to end.

use chat_crypto::{Client, CryptoError, Incoming};

/// Adds members and merges the commit (as the app does once the server accepts it).
fn add(c: &mut Client, group: &[u8], kps: Vec<Vec<u8>>) -> (Vec<u8>, Vec<u8>) {
    let out = c.add_members(group, kps).unwrap();
    c.merge_pending_commit(group).unwrap();
    (out.commit, out.welcome.unwrap())
}

fn remove(c: &mut Client, group: &[u8], ids: Vec<Vec<u8>>) -> Vec<u8> {
    let out = c.remove_members(group, ids).unwrap();
    c.merge_pending_commit(group).unwrap();
    out.commit
}

const GROUP: &[u8] = b"conversation-1";

fn client(name: &str) -> Client {
    Client::new(name.as_bytes().to_vec()).unwrap()
}

fn app(sender: &str, text: &str) -> Incoming {
    Incoming::Application {
        sender: sender.as_bytes().to_vec(),
        plaintext: text.as_bytes().to_vec(),
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// Alice creates the conversation and invites Bob from his published KeyPackage.
fn direct_chat() -> (Client, Client) {
    let mut alice = client("alice");
    let mut bob = client("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    let (_commit, welcome) = add(&mut alice, GROUP, vec![bob.generate_key_package().unwrap()]);
    assert_eq!(bob.join_group(welcome).unwrap(), GROUP);
    (alice, bob)
}

#[test]
fn direct_conversation_round_trip() {
    let (mut alice, mut bob) = direct_chat();

    let c1 = alice.encrypt(GROUP, b"oi bob".to_vec()).unwrap();
    assert_eq!(bob.process(GROUP, c1).unwrap(), app("alice", "oi bob"));

    let c2 = bob.encrypt(GROUP, b"oi alice".to_vec()).unwrap();
    assert_eq!(alice.process(GROUP, c2).unwrap(), app("bob", "oi alice"));

    assert_eq!(alice.members(GROUP).unwrap(), bob.members(GROUP).unwrap());
    assert_eq!(
        alice.epoch_authenticator(GROUP).unwrap(),
        bob.epoch_authenticator(GROUP).unwrap()
    );
}

#[test]
fn server_only_sees_ciphertext() {
    let (mut alice, _bob) = direct_chat();
    let secret = b"minha senha do banco e 1234";
    let wire = alice.encrypt(GROUP, secret.to_vec()).unwrap();
    assert!(!contains(&wire, secret));
    assert!(!contains(&wire, b"senha"));
}

#[test]
fn padding_hides_message_length() {
    let (mut alice, _bob) = direct_chat();
    let short = alice.encrypt(GROUP, b"a".to_vec()).unwrap();
    let longer = alice
        .encrypt(GROUP, b"mensagem um pouco maior".to_vec())
        .unwrap();
    assert_eq!(short.len(), longer.len());
}

#[test]
fn group_of_three_with_late_joiner() {
    let (mut alice, mut bob) = direct_chat();
    let mut carol = client("carol");

    let (commit, welcome) = add(
        &mut alice,
        GROUP,
        vec![carol.generate_key_package().unwrap()],
    );
    assert_eq!(
        bob.process(GROUP, commit).unwrap(),
        Incoming::Commit { still_member: true }
    );
    carol.join_group(welcome).unwrap();

    for c in [&alice, &bob, &carol] {
        assert_eq!(c.members(GROUP).unwrap().len(), 3);
        assert_eq!(c.epoch(GROUP).unwrap(), 2);
    }
    assert_eq!(
        alice.epoch_authenticator(GROUP).unwrap(),
        carol.epoch_authenticator(GROUP).unwrap()
    );

    let msg = carol.encrypt(GROUP, b"oi grupo".to_vec()).unwrap();
    assert_eq!(
        alice.process(GROUP, msg.clone()).unwrap(),
        app("carol", "oi grupo")
    );
    assert_eq!(bob.process(GROUP, msg).unwrap(), app("carol", "oi grupo"));
}

#[test]
fn late_joiner_cannot_read_history() {
    let (mut alice, mut bob) = direct_chat();
    let before = alice.encrypt(GROUP, b"antes da carol".to_vec()).unwrap();
    assert_eq!(
        bob.process(GROUP, before.clone()).unwrap(),
        app("alice", "antes da carol")
    );

    let mut carol = client("carol");
    let (commit, welcome) = add(
        &mut alice,
        GROUP,
        vec![carol.generate_key_package().unwrap()],
    );
    bob.process(GROUP, commit).unwrap();
    carol.join_group(welcome).unwrap();

    assert!(carol.process(GROUP, before).is_err());
}

#[test]
fn removed_member_cannot_read_new_messages() {
    let (mut alice, mut bob) = direct_chat();
    let mut carol = client("carol");
    let (commit, welcome) = add(
        &mut alice,
        GROUP,
        vec![carol.generate_key_package().unwrap()],
    );
    bob.process(GROUP, commit).unwrap();
    carol.join_group(welcome).unwrap();

    let commit = remove(&mut alice, GROUP, vec![b"carol".to_vec()]);
    assert_eq!(
        bob.process(GROUP, commit.clone()).unwrap(),
        Incoming::Commit { still_member: true }
    );
    assert_eq!(
        carol.process(GROUP, commit).unwrap(),
        Incoming::Commit {
            still_member: false
        }
    );
    assert_eq!(
        alice.members(GROUP).unwrap(),
        vec![b"alice".to_vec(), b"bob".to_vec()]
    );

    let after = alice.encrypt(GROUP, b"carol nao le isto".to_vec()).unwrap();
    assert_eq!(
        bob.process(GROUP, after.clone()).unwrap(),
        app("alice", "carol nao le isto")
    );
    assert!(carol.process(GROUP, after).is_err());
    assert!(carol.encrypt(GROUP, b"x".to_vec()).is_err());
}

#[test]
fn old_epoch_keys_are_deleted() {
    // Keys of epochs older than the small retention window are erased, so a
    // message from that far back can no longer be decrypted (forward secrecy).
    let (mut alice, mut bob) = direct_chat();
    let stale = alice.encrypt(GROUP, b"epoca antiga".to_vec()).unwrap();
    for _ in 0..4 {
        let out = alice.self_update(GROUP).unwrap();
        alice.merge_pending_commit(GROUP).unwrap();
        bob.process(GROUP, out.commit).unwrap();
    }
    assert!(bob.process(GROUP, stale).is_err());
}

#[test]
fn tampered_message_is_rejected() {
    let (mut alice, mut bob) = direct_chat();
    let mut wire = alice.encrypt(GROUP, b"integridade".to_vec()).unwrap();
    let last = wire.len() - 1;
    wire[last] ^= 0x01;
    assert!(bob.process(GROUP, wire).is_err());
}

#[test]
fn replayed_message_is_rejected() {
    let (mut alice, mut bob) = direct_chat();
    let wire = alice.encrypt(GROUP, b"uma vez so".to_vec()).unwrap();
    bob.process(GROUP, wire.clone()).unwrap();
    assert!(bob.process(GROUP, wire).is_err());
}

#[test]
fn outsider_cannot_decrypt() {
    let (mut alice, _bob) = direct_chat();
    let mut eve = client("eve");
    eve.create_group(GROUP.to_vec()).unwrap(); // same group id, different keys
    let wire = alice.encrypt(GROUP, b"privado".to_vec()).unwrap();
    assert!(eve.process(GROUP, wire).is_err());
}

#[test]
fn tampered_key_package_is_rejected() {
    let mut alice = client("alice");
    let bob = client("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    let mut kp = bob.generate_key_package().unwrap();
    let mid = kp.len() / 2;
    kp[mid] ^= 0x01;
    assert!(alice.add_members(GROUP, vec![kp]).is_err());
}

#[test]
fn key_package_is_single_use() {
    let mut alice = client("alice");
    let mut bob = client("bob");
    let kp = bob.generate_key_package().unwrap();

    alice.create_group(b"g1".to_vec()).unwrap();
    alice.create_group(b"g2".to_vec()).unwrap();
    let (_, w1) = add(&mut alice, b"g1", vec![kp.clone()]);
    let (_, w2) = add(&mut alice, b"g2", vec![kp]);

    bob.join_group(w1).unwrap();
    assert!(
        bob.join_group(w2).is_err(),
        "the private init key must be deleted after first use"
    );
}

#[test]
fn errors_are_explicit() {
    let mut alice = client("alice");
    assert!(matches!(
        alice.encrypt(b"nope", b"x".to_vec()),
        Err(CryptoError::UnknownGroup)
    ));
    assert!(matches!(
        Client::new(vec![]),
        Err(CryptoError::InvalidInput(_))
    ));
    alice.create_group(GROUP.to_vec()).unwrap();
    assert!(matches!(
        alice.remove_members(GROUP, vec![b"ghost".to_vec()]),
        Err(CryptoError::UnknownMember)
    ));
    assert!(alice.join_group(b"lixo".to_vec()).is_err());
}

#[test]
fn foreign_ciphersuite_key_package_is_rejected_early() {
    let mut alice = client("alice");
    let bob = client("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    let mut kp = bob.generate_key_package().unwrap();
    assert_eq!(&kp[2..4], &[0x00, 0x01]); // MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519
    kp[3] = 0x02; // claim MLS_128_DHKEMP256_AES128GCM_SHA256_P256
    let err = alice.add_members(GROUP, vec![kp]).unwrap_err();
    assert!(matches!(err, CryptoError::InvalidInput(_)));
}

#[test]
fn joining_same_group_twice_is_rejected() {
    let mut alice = client("alice");
    let mut bob = client("bob");
    alice.create_group(GROUP.to_vec()).unwrap();
    let (_commit, welcome) = add(&mut alice, GROUP, vec![bob.generate_key_package().unwrap()]);
    bob.join_group(welcome.clone()).unwrap();
    assert!(bob.join_group(welcome).is_err());
}

#[test]
fn state_survives_export_and_restore() {
    let key = chat_crypto::random_bytes(32).unwrap();
    let (mut alice, bob) = direct_chat();
    let bob_state = bob.export_state(&key).unwrap();
    drop(bob);
    let mut bob = Client::restore(&bob_state, &key).unwrap();
    assert_eq!(bob.identity(), b"bob");
    assert_eq!(bob.group_ids(), vec![GROUP.to_vec()]);

    let wire = alice
        .encrypt(GROUP, b"depois de reiniciar".to_vec())
        .unwrap();
    assert_eq!(
        bob.process(GROUP, wire).unwrap(),
        app("alice", "depois de reiniciar")
    );

    // A key package generated before the restart can still be used to join.
    let mut carol = client("carol");
    let kp = carol.generate_key_package().unwrap();
    let carol_state = carol.export_state(&key).unwrap();
    carol = Client::restore(&carol_state, &key).unwrap();
    let (commit, welcome) = add(&mut alice, GROUP, vec![kp]);
    bob.process(GROUP, commit).unwrap();
    carol.join_group(welcome).unwrap();
    assert_eq!(carol.members(GROUP).unwrap().len(), 3);
}

#[test]
fn state_needs_the_right_key() {
    let key = chat_crypto::random_bytes(32).unwrap();
    let state = client("alice").export_state(&key).unwrap();
    assert!(Client::restore(&state, &chat_crypto::random_bytes(32).unwrap()).is_err());
    let mut bad = state.clone();
    bad[20] ^= 1;
    assert!(Client::restore(&bad, &key).is_err());
    assert!(!String::from_utf8_lossy(&state).contains("alice"));
}

#[test]
fn concurrent_commits_converge() {
    // Alice and Bob both commit at the same epoch; the server accepts Alice's.
    let (mut alice, mut bob) = direct_chat();
    let a = alice.self_update(GROUP).unwrap();
    let _b = bob.self_update(GROUP).unwrap();
    assert!(bob.has_pending_commit(GROUP).unwrap());

    alice.merge_pending_commit(GROUP).unwrap(); // server accepted Alice
                                                // Bob receives Alice's commit while holding his own pending one.
    assert_eq!(
        bob.process(GROUP, a.commit).unwrap(),
        Incoming::Commit { still_member: true }
    );
    assert!(!bob.has_pending_commit(GROUP).unwrap());
    assert_eq!(alice.epoch(GROUP).unwrap(), bob.epoch(GROUP).unwrap());
    assert_eq!(
        alice.epoch_authenticator(GROUP).unwrap(),
        bob.epoch_authenticator(GROUP).unwrap()
    );

    let wire = bob.encrypt(GROUP, b"convergiu".to_vec()).unwrap();
    assert_eq!(alice.process(GROUP, wire).unwrap(), app("bob", "convergiu"));
}

#[test]
fn rejected_commit_can_be_cleared() {
    let (mut alice, mut bob) = direct_chat();
    let epoch = alice.epoch(GROUP).unwrap();
    let out = alice.self_update(GROUP).unwrap();
    assert_eq!(out.new_epoch, epoch + 1);
    alice.clear_pending_commit(GROUP).unwrap();
    assert_eq!(alice.epoch(GROUP).unwrap(), epoch);
    let wire = alice
        .encrypt(GROUP, b"ainda na mesma epoca".to_vec())
        .unwrap();
    assert_eq!(
        bob.process(GROUP, wire).unwrap(),
        app("alice", "ainda na mesma epoca")
    );
    assert!(alice.merge_pending_commit(GROUP).is_err());
}

#[test]
fn self_update_rotates_keys() {
    let (mut alice, mut bob) = direct_chat();
    let before = alice.epoch_authenticator(GROUP).unwrap();
    let out = alice.self_update(GROUP).unwrap();
    alice.merge_pending_commit(GROUP).unwrap();
    bob.process(GROUP, out.commit).unwrap();
    assert_ne!(alice.epoch_authenticator(GROUP).unwrap(), before);
    assert_eq!(
        alice.epoch_authenticator(GROUP).unwrap(),
        bob.epoch_authenticator(GROUP).unwrap()
    );
}

#[test]
fn late_message_within_past_epochs_still_decrypts() {
    let (mut alice, mut bob) = direct_chat();
    let late = alice.encrypt(GROUP, b"atrasada".to_vec()).unwrap();
    let out = alice.self_update(GROUP).unwrap();
    alice.merge_pending_commit(GROUP).unwrap();
    bob.process(GROUP, out.commit).unwrap();
    assert_eq!(bob.process(GROUP, late).unwrap(), app("alice", "atrasada"));
}

#[test]
fn member_infos_and_delete_group() {
    let (alice, mut bob) = direct_chat();
    let infos = bob.member_infos(GROUP).unwrap();
    assert_eq!(infos.len(), 2);
    let a = infos.iter().find(|m| m.identity == b"alice").unwrap();
    assert_eq!(a.signature_key, alice.signature_public_key());
    bob.delete_group(GROUP).unwrap();
    assert!(!bob.has_group(GROUP));
    assert!(bob.encrypt(GROUP, b"x".to_vec()).is_err());
}

#[test]
fn generates_many_key_packages() {
    let kps = client("alice").generate_key_packages(5).unwrap();
    assert_eq!(kps.len(), 5);
    assert_eq!(
        kps.iter().collect::<std::collections::HashSet<_>>().len(),
        5
    );
}

#[test]
fn last_resort_key_package_can_be_reused() {
    // Unlike a normal KeyPackage, a last-resort one keeps working for several
    // groups, so draining the pool of normal ones cannot lock someone out.
    let mut alice = client("alice");
    let mut bob = client("bob");
    let kp = bob.generate_last_resort_key_package().unwrap();

    alice.create_group(b"g1".to_vec()).unwrap();
    alice.create_group(b"g2".to_vec()).unwrap();
    let (_, w1) = add(&mut alice, b"g1", vec![kp.clone()]);
    let (_, w2) = add(&mut alice, b"g2", vec![kp]);

    assert_eq!(bob.join_group(w1).unwrap(), b"g1".to_vec());
    assert_eq!(
        bob.join_group(w2).unwrap(),
        b"g2".to_vec(),
        "last resort is reusable"
    );

    let wire = alice.encrypt(b"g2", b"funciona".to_vec()).unwrap();
    assert_eq!(
        bob.process(b"g2", wire).unwrap(),
        Incoming::Application {
            sender: b"alice".to_vec(),
            plaintext: b"funciona".to_vec()
        }
    );
}

#[test]
fn last_resort_survives_state_restore() {
    let key = chat_crypto::random_bytes(32).unwrap();
    let mut alice = client("alice");
    let bob = client("bob");
    let kp = bob.generate_last_resort_key_package().unwrap();
    let mut bob = Client::restore(&bob.export_state(&key).unwrap(), &key).unwrap();

    alice.create_group(GROUP.to_vec()).unwrap();
    let (_, welcome) = add(&mut alice, GROUP, vec![kp]);
    assert_eq!(bob.join_group(welcome).unwrap(), GROUP);
}
