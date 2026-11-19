//! Stage 0 proof of concept: the properties the chat needs, end to end.

use chat_crypto::{Client, CryptoError, Incoming};

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
    let out = alice
        .add_members(GROUP, vec![bob.generate_key_package().unwrap()])
        .unwrap();
    assert_eq!(bob.join_group(out.welcome).unwrap(), GROUP);
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

    let out = alice
        .add_members(GROUP, vec![carol.generate_key_package().unwrap()])
        .unwrap();
    assert_eq!(
        bob.process(GROUP, out.commit).unwrap(),
        Incoming::Commit { still_member: true }
    );
    carol.join_group(out.welcome).unwrap();

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
    let out = alice
        .add_members(GROUP, vec![carol.generate_key_package().unwrap()])
        .unwrap();
    bob.process(GROUP, out.commit).unwrap();
    carol.join_group(out.welcome).unwrap();

    assert!(carol.process(GROUP, before).is_err());
}

#[test]
fn removed_member_cannot_read_new_messages() {
    let (mut alice, mut bob) = direct_chat();
    let mut carol = client("carol");
    let out = alice
        .add_members(GROUP, vec![carol.generate_key_package().unwrap()])
        .unwrap();
    bob.process(GROUP, out.commit).unwrap();
    carol.join_group(out.welcome).unwrap();

    let commit = alice
        .remove_members(GROUP, vec![b"carol".to_vec()])
        .unwrap();
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
    // A message from an epoch that the receiver already left behind can no
    // longer be decrypted: old keys are erased (forward secrecy).
    let (mut alice, mut bob) = direct_chat();
    let stale = alice.encrypt(GROUP, b"epoca antiga".to_vec()).unwrap();

    let carol = client("carol");
    let out = alice
        .add_members(GROUP, vec![carol.generate_key_package().unwrap()])
        .unwrap();
    bob.process(GROUP, out.commit).unwrap();

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
    let w1 = alice.add_members(b"g1", vec![kp.clone()]).unwrap().welcome;
    let w2 = alice.add_members(b"g2", vec![kp]).unwrap().welcome;

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
    let w = alice
        .add_members(GROUP, vec![bob.generate_key_package().unwrap()])
        .unwrap()
        .welcome;
    bob.join_group(w.clone()).unwrap();
    assert!(bob.join_group(w).is_err());
}
