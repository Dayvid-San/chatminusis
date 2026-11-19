//! Dart-facing API. Thin wrapper over `chat_crypto` (rust/chat_crypto):
//! no cryptographic logic lives here.

use flutter_rust_bridge::frb;

/// Kind of a processed incoming group message.
pub enum IncomingKind {
    /// Decrypted chat message: `sender` and `plaintext` are set.
    Application,
    /// Membership/key change applied: `still_member` says if we are still in the group.
    Commit,
    /// Proposal stored for a later commit.
    Proposal,
    /// Our own message echoed back by the server.
    Own,
}

pub struct IncomingMessage {
    pub kind: IncomingKind,
    pub sender: Vec<u8>,
    pub plaintext: Vec<u8>,
    pub still_member: bool,
}

/// Pending commit to publish; call `merge_pending_commit` once the server accepts it.
pub struct CommitResult {
    pub commit: Vec<u8>,
    /// Present when members were added: send to them.
    pub welcome: Option<Vec<u8>>,
    pub new_epoch: u64,
}

pub struct MemberKey {
    pub identity: Vec<u8>,
    pub signature_key: Vec<u8>,
}

fn commit(out: chat_crypto::CommitOutput) -> CommitResult {
    CommitResult { commit: out.commit, welcome: out.welcome, new_epoch: out.new_epoch }
}

/// One device's MLS identity and its groups. Opaque on the Dart side.
#[frb(opaque)]
pub struct ChatCryptoClient {
    inner: chat_crypto::Client,
}

impl ChatCryptoClient {
    #[frb(sync)]
    pub fn create(identity: Vec<u8>) -> anyhow::Result<ChatCryptoClient> {
        Ok(Self { inner: chat_crypto::Client::new(identity)? })
    }

    /// Restores a client sealed with `export_state` (key: 32 bytes from the keystore).
    pub fn restore(state: Vec<u8>, key: Vec<u8>) -> anyhow::Result<ChatCryptoClient> {
        Ok(Self { inner: chat_crypto::Client::restore(&state, &key)? })
    }

    pub fn export_state(&self, key: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.export_state(&key)?)
    }

    #[frb(sync, getter)]
    pub fn identity(&self) -> Vec<u8> {
        self.inner.identity()
    }

    #[frb(sync, getter)]
    pub fn signature_public_key(&self) -> Vec<u8> {
        self.inner.signature_public_key()
    }

    pub fn generate_key_packages(&self, count: u32) -> anyhow::Result<Vec<Vec<u8>>> {
        Ok(self.inner.generate_key_packages(count)?)
    }

    pub fn generate_key_package(&self) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.generate_key_package()?)
    }

    #[frb(sync)]
    pub fn has_group(&self, group_id: Vec<u8>) -> bool {
        self.inner.has_group(&group_id)
    }

    #[frb(sync)]
    pub fn group_ids(&self) -> Vec<Vec<u8>> {
        self.inner.group_ids()
    }

    pub fn create_group(&mut self, group_id: Vec<u8>) -> anyhow::Result<()> {
        Ok(self.inner.create_group(group_id)?)
    }

    pub fn delete_group(&mut self, group_id: Vec<u8>) -> anyhow::Result<()> {
        Ok(self.inner.delete_group(&group_id)?)
    }

    pub fn add_members(&mut self, group_id: Vec<u8>, key_packages: Vec<Vec<u8>>) -> anyhow::Result<CommitResult> {
        Ok(commit(self.inner.add_members(&group_id, key_packages)?))
    }

    pub fn remove_members(&mut self, group_id: Vec<u8>, identities: Vec<Vec<u8>>) -> anyhow::Result<CommitResult> {
        Ok(commit(self.inner.remove_members(&group_id, identities)?))
    }

    pub fn self_update(&mut self, group_id: Vec<u8>) -> anyhow::Result<CommitResult> {
        Ok(commit(self.inner.self_update(&group_id)?))
    }

    pub fn merge_pending_commit(&mut self, group_id: Vec<u8>) -> anyhow::Result<()> {
        Ok(self.inner.merge_pending_commit(&group_id)?)
    }

    pub fn clear_pending_commit(&mut self, group_id: Vec<u8>) -> anyhow::Result<()> {
        Ok(self.inner.clear_pending_commit(&group_id)?)
    }

    pub fn join_group(&mut self, welcome: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.join_group(welcome)?)
    }

    pub fn encrypt(&mut self, group_id: Vec<u8>, plaintext: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.encrypt(&group_id, plaintext)?)
    }

    pub fn process(&mut self, group_id: Vec<u8>, message: Vec<u8>) -> anyhow::Result<IncomingMessage> {
        use chat_crypto::Incoming;
        let empty = IncomingMessage { kind: IncomingKind::Own, sender: vec![], plaintext: vec![], still_member: true };
        Ok(match self.inner.process(&group_id, message)? {
            Incoming::Application { sender, plaintext } => {
                IncomingMessage { kind: IncomingKind::Application, sender, plaintext, ..empty }
            }
            Incoming::Commit { still_member } => IncomingMessage { kind: IncomingKind::Commit, still_member, ..empty },
            Incoming::Proposal => IncomingMessage { kind: IncomingKind::Proposal, ..empty },
            Incoming::Own => empty,
        })
    }

    #[frb(sync)]
    pub fn members(&self, group_id: Vec<u8>) -> anyhow::Result<Vec<Vec<u8>>> {
        Ok(self.inner.members(&group_id)?)
    }

    #[frb(sync)]
    pub fn member_keys(&self, group_id: Vec<u8>) -> anyhow::Result<Vec<MemberKey>> {
        Ok(self
            .inner
            .member_infos(&group_id)?
            .into_iter()
            .map(|m| MemberKey { identity: m.identity, signature_key: m.signature_key })
            .collect())
    }

    #[frb(sync)]
    pub fn epoch(&self, group_id: Vec<u8>) -> anyhow::Result<u64> {
        Ok(self.inner.epoch(&group_id)?)
    }

    #[frb(sync)]
    pub fn epoch_authenticator(&self, group_id: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.epoch_authenticator(&group_id)?)
    }
}

/// Secure random bytes from the OS.
#[frb(sync)]
pub fn random_bytes(len: u32) -> anyhow::Result<Vec<u8>> {
    Ok(chat_crypto::random_bytes(len as usize)?)
}

/// AES-256-GCM seal for local data. `context` is authenticated (e.g. file name).
pub fn vault_seal(key: Vec<u8>, context: Vec<u8>, plaintext: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(chat_crypto::vault::seal(&key, &context, &plaintext)?)
}

pub fn vault_open(key: Vec<u8>, context: Vec<u8>, sealed: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(chat_crypto::vault::open(&key, &context, &sealed)?)
}

/// 60-digit safety number, identical on both sides.
pub fn safety_number(my_identity: Vec<u8>, my_key: Vec<u8>, their_identity: Vec<u8>, their_key: Vec<u8>) -> String {
    chat_crypto::safety::safety_number(&my_identity, &my_key, &their_identity, &their_key)
}

/// New 260-bit recovery code (52 characters in groups of 4).
#[frb(sync)]
pub fn generate_recovery_code() -> anyhow::Result<String> {
    Ok(chat_crypto::backup::generate_recovery_code()?)
}

#[frb(sync)]
pub fn is_valid_recovery_code(code: String) -> bool {
    chat_crypto::backup::normalize_recovery_code(&code).is_ok()
}

/// Encrypts a backup: needs the recovery code AND the 32-byte server share.
pub fn backup_seal(recovery_code: String, server_share: Vec<u8>, plaintext: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(chat_crypto::backup::seal(&recovery_code, &server_share, &plaintext)?)
}

pub fn backup_open(recovery_code: String, server_share: Vec<u8>, blob: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(chat_crypto::backup::open(&recovery_code, &server_share, &blob)?)
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
