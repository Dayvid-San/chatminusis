//! E2EE core for the chat app.
//!
//! Every conversation (1:1 or group) is an MLS group (RFC 9420). The server
//! only ever sees the opaque byte blobs produced here: KeyPackages, Commits,
//! Welcomes and encrypted application messages.
//!
//! The API deliberately uses only `Vec<u8>`, `String`, `u64` and plain structs
//! so it can be exposed to Dart with `flutter_rust_bridge` without wrappers.
//!
//! Stage 0 (proof of concept): state is kept in memory. Persistent, encrypted
//! storage of keys and group state is Stage 5/8 of the roadmap.

use std::collections::HashMap;

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tls_codec::{Deserialize as _, Serialize as _};

/// Ciphersuite used by every group.
///
/// X25519 key exchange, AES-128-GCM AEAD, SHA-256 and Ed25519 signatures:
/// the MLS mandatory-to-implement suite. A hybrid post-quantum suite
/// (X25519 + ML-KEM) is planned once it is stable in OpenMLS.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Messages are padded to a multiple of this many bytes to hide their exact length.
const PADDING_SIZE: usize = 64;

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("unknown group")]
    UnknownGroup,
    #[error("member not found in group")]
    UnknownMember,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("mls error: {0}")]
    Mls(String),
}

fn mls<E: std::fmt::Debug>(e: E) -> CryptoError {
    CryptoError::Mls(format!("{e:?}"))
}

pub type Result<T> = std::result::Result<T, CryptoError>;

/// Result of adding members: the Commit goes to existing members, the Welcome
/// to the new ones.
#[derive(Debug, Clone)]
pub struct AddMembersOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// What a received message turned out to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    /// A decrypted chat message.
    Application { sender: Vec<u8>, plaintext: Vec<u8> },
    /// A membership/key change that was applied. `still_member` is false when
    /// this client was removed by the commit.
    Commit { still_member: bool },
    /// A proposal that was stored for a later commit.
    Proposal,
    /// This client's own message echoed back by the server; nothing to do.
    Own,
}

/// One user's device: its signing identity plus all the groups it belongs to.
pub struct Client {
    identity: Vec<u8>,
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    groups: HashMap<Vec<u8>, MlsGroup>,
}

impl Client {
    /// Creates a new identity. `identity` is the stable user id (e.g. the uid).
    pub fn new(identity: Vec<u8>) -> Result<Self> {
        if identity.is_empty() {
            return Err(CryptoError::InvalidInput("empty identity".into()));
        }
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(mls)?;
        signer.store(provider.storage()).map_err(mls)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.clone()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            identity,
            provider,
            signer,
            credential,
            groups: HashMap::new(),
        })
    }

    pub fn identity(&self) -> Vec<u8> {
        self.identity.clone()
    }

    /// Public signature key; its fingerprint is what users compare to verify each other.
    pub fn signature_public_key(&self) -> Vec<u8> {
        self.signer.to_public_vec()
    }

    /// Creates a single-use KeyPackage to publish on the server so others can
    /// add this client to a group while it is offline.
    pub fn generate_key_package(&self) -> Result<Vec<u8>> {
        let bundle = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(mls)?;
        bundle.key_package().tls_serialize_detached().map_err(mls)
    }

    fn create_config() -> MlsGroupCreateConfig {
        MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .padding_size(PADDING_SIZE)
            .use_ratchet_tree_extension(true)
            .build()
    }

    fn join_config() -> MlsGroupJoinConfig {
        MlsGroupJoinConfig::builder()
            .padding_size(PADDING_SIZE)
            .use_ratchet_tree_extension(true)
            .build()
    }

    fn group(&self, group_id: &[u8]) -> Result<&MlsGroup> {
        self.groups.get(group_id).ok_or(CryptoError::UnknownGroup)
    }

    /// Creates a new group (conversation) with this client as the only member.
    pub fn create_group(&mut self, group_id: Vec<u8>) -> Result<()> {
        if self.groups.contains_key(&group_id) {
            return Err(CryptoError::InvalidInput("group already exists".into()));
        }
        let group = MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &Self::create_config(),
            GroupId::from_slice(&group_id),
            self.credential.clone(),
        )
        .map_err(mls)?;
        self.groups.insert(group_id, group);
        Ok(())
    }

    /// Adds members from their published KeyPackages. Signatures and lifetimes
    /// of the KeyPackages are verified.
    pub fn add_members(
        &mut self,
        group_id: &[u8],
        key_packages: Vec<Vec<u8>>,
    ) -> Result<AddMembersOutput> {
        let mut validated = Vec::with_capacity(key_packages.len());
        for bytes in key_packages {
            // Reject any other ciphersuite before touching its crypto code: only
            // X25519/Ed25519 is accepted (see RUSTSEC-2026-0387 note in rust/deny.toml).
            if declared_ciphersuite(&bytes) != Some(CIPHERSUITE as u16) {
                return Err(CryptoError::InvalidInput(
                    "unsupported key package ciphersuite".into(),
                ));
            }
            let kp = KeyPackageIn::tls_deserialize_exact(bytes.as_slice()).map_err(mls)?;
            let kp = kp
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(mls)?;
            if kp.ciphersuite() != CIPHERSUITE {
                return Err(CryptoError::InvalidInput(
                    "unsupported key package ciphersuite".into(),
                ));
            }
            validated.push(kp);
        }
        let provider = &self.provider;
        let signer = &self.signer;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let (commit, welcome, _group_info) = group
            .add_members(provider, signer, &validated)
            .map_err(mls)?;
        group.merge_pending_commit(provider).map_err(mls)?;
        Ok(AddMembersOutput {
            commit: commit.tls_serialize_detached().map_err(mls)?,
            welcome: welcome.tls_serialize_detached().map_err(mls)?,
        })
    }

    /// Joins a group from a Welcome message. Returns the group id.
    pub fn join_group(&mut self, welcome: Vec<u8>) -> Result<Vec<u8>> {
        let msg = MlsMessageIn::tls_deserialize_exact(welcome.as_slice()).map_err(mls)?;
        let welcome = match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(CryptoError::InvalidInput("not a welcome message".into())),
        };
        let group =
            StagedWelcome::new_from_welcome(&self.provider, &Self::join_config(), welcome, None)
                .map_err(mls)?
                .into_group(&self.provider)
                .map_err(mls)?;
        if group.ciphersuite() != CIPHERSUITE {
            return Err(CryptoError::InvalidInput(
                "unsupported group ciphersuite".into(),
            ));
        }
        let id = group.group_id().as_slice().to_vec();
        if self.groups.contains_key(&id) {
            return Err(CryptoError::InvalidInput("group already exists".into()));
        }
        self.groups.insert(id.clone(), group);
        Ok(id)
    }

    /// Removes members by identity. Returns the Commit to send to the group.
    pub fn remove_members(&mut self, group_id: &[u8], identities: Vec<Vec<u8>>) -> Result<Vec<u8>> {
        let provider = &self.provider;
        let signer = &self.signer;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let mut indices = Vec::new();
        for id in &identities {
            let member = group
                .members()
                .find(|m| member_identity(&m.credential).as_deref() == Some(id.as_slice()))
                .ok_or(CryptoError::UnknownMember)?;
            indices.push(member.index);
        }
        let (commit, _welcome, _info) = group
            .remove_members(provider, signer, &indices)
            .map_err(mls)?;
        group.merge_pending_commit(provider).map_err(mls)?;
        commit.tls_serialize_detached().map_err(mls)
    }

    /// Encrypts a chat message for every current member of the group.
    pub fn encrypt(&mut self, group_id: &[u8], plaintext: Vec<u8>) -> Result<Vec<u8>> {
        let provider = &self.provider;
        let signer = &self.signer;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let msg = group
            .create_message(provider, signer, &plaintext)
            .map_err(mls)?;
        msg.tls_serialize_detached().map_err(mls)
    }

    /// Processes any group message received from the server: decrypts chat
    /// messages and applies Commits (membership and key updates).
    pub fn process(&mut self, group_id: &[u8], message: Vec<u8>) -> Result<Incoming> {
        let provider = &self.provider;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let msg = MlsMessageIn::tls_deserialize_exact(message.as_slice()).map_err(mls)?;
        let protocol = msg
            .try_into_protocol_message()
            .map_err(|_| CryptoError::InvalidInput("not a group message".into()))?;
        let processed = group.process_message(provider, protocol).map_err(mls)?;
        let sender = member_identity(processed.credential()).unwrap_or_default();
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => Ok(Incoming::Application {
                sender,
                plaintext: app.into_bytes(),
            }),
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group.merge_staged_commit(provider, *staged).map_err(mls)?;
                Ok(Incoming::Commit {
                    still_member: group.is_active(),
                })
            }
            ProcessedMessageContent::ProposalMessage(proposal) => {
                group
                    .store_pending_proposal(provider.storage(), *proposal)
                    .map_err(mls)?;
                Ok(Incoming::Proposal)
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(_) => Ok(Incoming::Proposal),
            ProcessedMessageContent::OwnPendingCommit
            | ProcessedMessageContent::OwnPrivateMessage => Ok(Incoming::Own),
        }
    }

    /// Identities of the current members, in tree order.
    pub fn members(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        Ok(self
            .group(group_id)?
            .members()
            .filter_map(|m| member_identity(&m.credential))
            .collect())
    }

    /// Current epoch; it increases with every Commit (key rotation).
    pub fn epoch(&self, group_id: &[u8]) -> Result<u64> {
        Ok(self.group(group_id)?.epoch().as_u64())
    }

    /// Value that every member of the same epoch computes identically. Comparing
    /// it out of band detects a server that split the group (basis for Stage 7).
    pub fn epoch_authenticator(&self, group_id: &[u8]) -> Result<Vec<u8>> {
        Ok(self
            .group(group_id)?
            .epoch_authenticator()
            .as_slice()
            .to_vec())
    }
}

/// Ciphersuite field of a serialized KeyPackage (RFC 9420 §10: version u16, then ciphersuite u16).
fn declared_ciphersuite(key_package: &[u8]) -> Option<u16> {
    key_package
        .get(2..4)
        .map(|b| u16::from_be_bytes([b[0], b[1]]))
}

fn member_identity(credential: &Credential) -> Option<Vec<u8>> {
    BasicCredential::try_from(credential.clone())
        .ok()
        .map(|c| c.identity().to_vec())
}
