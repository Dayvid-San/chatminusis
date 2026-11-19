//! MLS client: one device identity plus all its groups (conversations).
//!
//! Every conversation (1:1 or group) is an MLS group (RFC 9420). The server
//! only ever sees opaque blobs: KeyPackages, Commits, Welcomes and encrypted
//! application messages.
//!
//! Commits are created *pending*: the app publishes them and only calls
//! [`Client::merge_pending_commit`] after the server accepted them (epoch
//! compare-and-set), or [`Client::clear_pending_commit`] if another member won
//! the race. This keeps every member on the same epoch.

use std::collections::BTreeSet;

use openmls::prelude::*;
use openmls::treesync::LeafNodeParameters;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tls_codec::{Deserialize as _, Serialize as _};

use crate::{mls, vault, CryptoError, Result};

/// X25519 key exchange, AES-128-GCM, SHA-256 and Ed25519: the MLS
/// mandatory-to-implement suite. A hybrid post-quantum suite is planned once
/// it is final in OpenMLS.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Messages are padded to a multiple of this many bytes to hide their length.
const PADDING_SIZE: usize = 64;
/// Old epochs whose keys are kept to decrypt late messages. Small on purpose:
/// keys older than this are deleted (forward secrecy).
const MAX_PAST_EPOCHS: usize = 3;
/// Out-of-order tolerance within one epoch.
const OUT_OF_ORDER: u32 = 32;

const STATE_MAGIC: &[u8; 4] = b"CMS1";
const STATE_CONTEXT: &[u8] = b"chatminusis-mls-state-v1";

#[derive(Debug, Clone)]
pub struct AddMembersOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// A pending commit to publish. `welcome` is present when members were added.
#[derive(Debug, Clone)]
pub struct CommitOutput {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    /// Epoch the group will be in once the commit is merged.
    pub new_epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberInfo {
    pub identity: Vec<u8>,
    pub signature_key: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    /// A decrypted chat message.
    Application { sender: Vec<u8>, plaintext: Vec<u8> },
    /// A membership/key change that was applied. `still_member` is false when
    /// this client was removed.
    Commit { still_member: bool },
    /// A proposal stored for a later commit.
    Proposal,
    /// This client's own message echoed back by the server.
    Own,
}

pub struct Client {
    identity: Vec<u8>,
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    groups: std::collections::HashMap<Vec<u8>, MlsGroup>,
}

impl Client {
    /// Creates a brand-new identity. `identity` is the stable user id (uid).
    pub fn new(identity: Vec<u8>) -> Result<Self> {
        if identity.is_empty() {
            return Err(CryptoError::InvalidInput("empty identity".into()));
        }
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(mls)?;
        signer.store(provider.storage()).map_err(mls)?;
        Ok(Self::assemble(identity, provider, signer))
    }

    fn assemble(identity: Vec<u8>, provider: OpenMlsRustCrypto, signer: SignatureKeyPair) -> Self {
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.clone()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Self {
            identity,
            provider,
            signer,
            credential,
            groups: Default::default(),
        }
    }

    // ---------------------------------------------------------------- state

    /// Serializes the whole client (identity, private keys, key packages,
    /// groups) and seals it with `key` (32 bytes from the platform keystore).
    pub fn export_state(&self, key: &[u8]) -> Result<Vec<u8>> {
        let values = self
            .provider
            .storage()
            .values
            .read()
            .map_err(|_| CryptoError::Mls("storage lock".into()))?;
        let mut w = Writer::default();
        w.raw(STATE_MAGIC);
        w.bytes(&self.identity);
        w.bytes(&self.signer.to_public_vec());
        let ids: BTreeSet<&Vec<u8>> = self.groups.keys().collect();
        w.u32(ids.len() as u32);
        for id in ids {
            w.bytes(id);
        }
        let mut entries: Vec<_> = values.iter().collect();
        entries.sort();
        w.u32(entries.len() as u32);
        for (k, v) in entries {
            w.bytes(k);
            w.bytes(v);
        }
        let plain = zeroize::Zeroizing::new(w.0);
        vault::seal(key, STATE_CONTEXT, &plain)
    }

    /// Restores a client from [`Client::export_state`].
    pub fn restore(state: &[u8], key: &[u8]) -> Result<Self> {
        let plain = zeroize::Zeroizing::new(vault::open(key, STATE_CONTEXT, state)?);
        let mut r = Reader {
            buf: &plain,
            pos: 0,
        };
        if r.raw(4)? != STATE_MAGIC {
            return Err(CryptoError::InvalidInput("not an mls state".into()));
        }
        let identity = r.bytes()?.to_vec();
        let public_key = r.bytes()?.to_vec();
        let group_ids: Vec<Vec<u8>> = (0..r.u32()?)
            .map(|_| r.bytes().map(<[u8]>::to_vec))
            .collect::<Result<_>>()?;
        let provider = OpenMlsRustCrypto::default();
        {
            let mut values = provider
                .storage()
                .values
                .write()
                .map_err(|_| CryptoError::Mls("storage lock".into()))?;
            for _ in 0..r.u32()? {
                let k = r.bytes()?.to_vec();
                let v = r.bytes()?.to_vec();
                values.insert(k, v);
            }
        }
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &public_key,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or_else(|| CryptoError::InvalidInput("signature key missing from state".into()))?;
        let mut client = Self::assemble(identity, provider, signer);
        for id in group_ids {
            let group = MlsGroup::load(client.provider.storage(), &GroupId::from_slice(&id))
                .map_err(mls)?
                .ok_or_else(|| CryptoError::InvalidInput("group missing from state".into()))?;
            client.groups.insert(id, group);
        }
        Ok(client)
    }

    // ------------------------------------------------------------- identity

    pub fn identity(&self) -> Vec<u8> {
        self.identity.clone()
    }

    /// Public signature key; published and pinned by contacts (stage 7).
    pub fn signature_public_key(&self) -> Vec<u8> {
        self.signer.to_public_vec()
    }

    /// Creates single-use KeyPackages to publish so others can add this client
    /// to groups while it is offline.
    pub fn generate_key_packages(&self, count: u32) -> Result<Vec<Vec<u8>>> {
        (0..count)
            .map(|_| {
                let bundle = KeyPackage::builder()
                    .build(
                        CIPHERSUITE,
                        &self.provider,
                        &self.signer,
                        self.credential.clone(),
                    )
                    .map_err(mls)?;
                bundle.key_package().tls_serialize_detached().map_err(mls)
            })
            .collect()
    }

    pub fn generate_key_package(&self) -> Result<Vec<u8>> {
        Ok(self.generate_key_packages(1)?.remove(0))
    }

    /// Creates a *last-resort* KeyPackage (RFC 9420 §16.8): served only when
    /// all single-use KeyPackages are gone, so nobody can be locked out of
    /// being invited by someone who drained the pool. Unlike normal ones, its
    /// private init key is NOT deleted after a group is joined with it, so it
    /// can be used again. Regenerate it regularly (it expires like any other).
    pub fn generate_last_resort_key_package(&self) -> Result<Vec<u8>> {
        let capabilities =
            Capabilities::new(None, None, Some(&[ExtensionType::LastResort]), None, None);
        let bundle = KeyPackage::builder()
            .mark_as_last_resort()
            .leaf_node_capabilities(capabilities)
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(mls)?;
        bundle.key_package().tls_serialize_detached().map_err(mls)
    }

    // --------------------------------------------------------------- groups

    fn create_config() -> MlsGroupCreateConfig {
        MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .padding_size(PADDING_SIZE)
            .max_past_epochs(MAX_PAST_EPOCHS)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(OUT_OF_ORDER, 1000))
            .use_ratchet_tree_extension(true)
            .build()
    }

    fn join_config() -> MlsGroupJoinConfig {
        MlsGroupJoinConfig::builder()
            .padding_size(PADDING_SIZE)
            .max_past_epochs(MAX_PAST_EPOCHS)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(OUT_OF_ORDER, 1000))
            .use_ratchet_tree_extension(true)
            .build()
    }

    fn group(&self, group_id: &[u8]) -> Result<&MlsGroup> {
        self.groups.get(group_id).ok_or(CryptoError::UnknownGroup)
    }

    pub fn has_group(&self, group_id: &[u8]) -> bool {
        self.groups.contains_key(group_id)
    }

    pub fn group_ids(&self) -> Vec<Vec<u8>> {
        let mut ids: Vec<_> = self.groups.keys().cloned().collect();
        ids.sort();
        ids
    }

    /// Creates a group with this client as its only member (epoch 0).
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

    /// Forgets a group locally (after being removed or leaving) and erases its keys.
    pub fn delete_group(&mut self, group_id: &[u8]) -> Result<()> {
        let mut group = self
            .groups
            .remove(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        group.delete(self.provider.storage()).map_err(mls)
    }

    fn validate_key_packages(&self, key_packages: Vec<Vec<u8>>) -> Result<Vec<KeyPackage>> {
        let mut validated = Vec::with_capacity(key_packages.len());
        for bytes in key_packages {
            // Reject other ciphersuites before touching their crypto code
            // (see the RUSTSEC-2026-0387 note in deny.toml).
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
        Ok(validated)
    }

    /// Prepares a pending commit adding members from their KeyPackages.
    pub fn add_members(
        &mut self,
        group_id: &[u8],
        key_packages: Vec<Vec<u8>>,
    ) -> Result<CommitOutput> {
        let validated = self.validate_key_packages(key_packages)?;
        let (provider, signer) = (&self.provider, &self.signer);
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let (commit, welcome, _info) = group
            .add_members(provider, signer, &validated)
            .map_err(mls)?;
        Ok(CommitOutput {
            commit: commit.tls_serialize_detached().map_err(mls)?,
            welcome: Some(welcome.tls_serialize_detached().map_err(mls)?),
            new_epoch: group.epoch().as_u64() + 1,
        })
    }

    /// Prepares a pending commit removing members by identity.
    pub fn remove_members(
        &mut self,
        group_id: &[u8],
        identities: Vec<Vec<u8>>,
    ) -> Result<CommitOutput> {
        let (provider, signer) = (&self.provider, &self.signer);
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
        Ok(CommitOutput {
            commit: commit.tls_serialize_detached().map_err(mls)?,
            welcome: None,
            new_epoch: group.epoch().as_u64() + 1,
        })
    }

    /// Prepares a pending commit that rotates this member's keys
    /// (post-compromise security). Call periodically.
    pub fn self_update(&mut self, group_id: &[u8]) -> Result<CommitOutput> {
        let (provider, signer) = (&self.provider, &self.signer);
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let bundle = group
            .self_update(provider, signer, LeafNodeParameters::default())
            .map_err(mls)?;
        Ok(CommitOutput {
            commit: bundle.commit().tls_serialize_detached().map_err(mls)?,
            welcome: None,
            new_epoch: group.epoch().as_u64() + 1,
        })
    }

    /// The server accepted our pending commit: move to the new epoch.
    pub fn merge_pending_commit(&mut self, group_id: &[u8]) -> Result<()> {
        let provider = &self.provider;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        if group.pending_commit().is_none() {
            return Err(CryptoError::InvalidInput("no pending commit".into()));
        }
        group.merge_pending_commit(provider).map_err(mls)
    }

    /// The server rejected our pending commit (someone else committed first).
    pub fn clear_pending_commit(&mut self, group_id: &[u8]) -> Result<()> {
        let provider = &self.provider;
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        group.clear_pending_commit(provider.storage()).map_err(mls)
    }

    pub fn has_pending_commit(&self, group_id: &[u8]) -> Result<bool> {
        Ok(self.group(group_id)?.pending_commit().is_some())
    }

    /// Joins a group from a Welcome. Returns the group id.
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

    /// Encrypts a chat message for every current member.
    pub fn encrypt(&mut self, group_id: &[u8], plaintext: Vec<u8>) -> Result<Vec<u8>> {
        let (provider, signer) = (&self.provider, &self.signer);
        let group = self
            .groups
            .get_mut(group_id)
            .ok_or(CryptoError::UnknownGroup)?;
        let msg = group
            .create_message(provider, signer, &plaintext)
            .map_err(mls)?;
        msg.tls_serialize_detached().map_err(mls)
    }

    /// Processes a group message from the server: decrypts chat messages and
    /// applies Commits (membership and key changes).
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
                // Someone else's commit for this epoch won: drop ours if any.
                group
                    .clear_pending_commit(provider.storage())
                    .map_err(mls)?;
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

    pub fn members(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        Ok(self
            .group(group_id)?
            .members()
            .filter_map(|m| member_identity(&m.credential))
            .collect())
    }

    /// Members with their signature keys, to compare against pinned keys.
    pub fn member_infos(&self, group_id: &[u8]) -> Result<Vec<MemberInfo>> {
        Ok(self
            .group(group_id)?
            .members()
            .filter_map(|m| {
                member_identity(&m.credential).map(|identity| MemberInfo {
                    identity,
                    signature_key: m.signature_key,
                })
            })
            .collect())
    }

    pub fn epoch(&self, group_id: &[u8]) -> Result<u64> {
        Ok(self.group(group_id)?.epoch().as_u64())
    }

    pub fn is_active(&self, group_id: &[u8]) -> Result<bool> {
        Ok(self.group(group_id)?.is_active())
    }

    /// Identical for all members of the same epoch; comparing it out of band
    /// detects a server that split the group.
    pub fn epoch_authenticator(&self, group_id: &[u8]) -> Result<Vec<u8>> {
        Ok(self
            .group(group_id)?
            .epoch_authenticator()
            .as_slice()
            .to_vec())
    }
}

/// Ciphersuite field of a serialized KeyPackage (RFC 9420 §10).
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

#[derive(Default)]
struct Writer(Vec<u8>);

impl Writer {
    fn raw(&mut self, b: &[u8]) {
        self.0.extend_from_slice(b);
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    fn bytes(&mut self, b: &[u8]) {
        self.u32(b.len() as u32);
        self.raw(b);
    }
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn raw(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).filter(|e| *e <= self.buf.len());
        let end = end.ok_or_else(|| CryptoError::InvalidInput("truncated state".into()))?;
        let out = &self.buf[self.pos..end];
        self.pos = end;
        Ok(out)
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.raw(4)?.try_into().unwrap()))
    }
    fn bytes(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.raw(n)
    }
}
