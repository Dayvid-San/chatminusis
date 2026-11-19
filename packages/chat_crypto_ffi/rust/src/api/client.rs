//! Dart-facing API. Thin wrapper over `chat_crypto` (rust/chat_crypto):
//! no cryptographic logic lives here.

use flutter_rust_bridge::frb;

pub use chat_crypto::CIPHERSUITE;

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

pub struct AddMembersResult {
    /// Send to the members already in the group.
    pub commit: Vec<u8>,
    /// Send to the newly added members.
    pub welcome: Vec<u8>,
}

/// One device's MLS identity and its groups. Opaque on the Dart side.
#[frb(opaque)]
pub struct ChatCryptoClient {
    inner: chat_crypto::Client,
}

impl ChatCryptoClient {
    #[frb(sync)]
    pub fn create(identity: Vec<u8>) -> anyhow::Result<ChatCryptoClient> {
        Ok(Self {
            inner: chat_crypto::Client::new(identity)?,
        })
    }

    #[frb(sync, getter)]
    pub fn identity(&self) -> Vec<u8> {
        self.inner.identity()
    }

    #[frb(sync, getter)]
    pub fn signature_public_key(&self) -> Vec<u8> {
        self.inner.signature_public_key()
    }

    pub fn generate_key_package(&self) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.generate_key_package()?)
    }

    pub fn create_group(&mut self, group_id: Vec<u8>) -> anyhow::Result<()> {
        Ok(self.inner.create_group(group_id)?)
    }

    pub fn add_members(
        &mut self,
        group_id: Vec<u8>,
        key_packages: Vec<Vec<u8>>,
    ) -> anyhow::Result<AddMembersResult> {
        let out = self.inner.add_members(&group_id, key_packages)?;
        Ok(AddMembersResult {
            commit: out.commit,
            welcome: out.welcome,
        })
    }

    pub fn join_group(&mut self, welcome: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.join_group(welcome)?)
    }

    pub fn remove_members(
        &mut self,
        group_id: Vec<u8>,
        identities: Vec<Vec<u8>>,
    ) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.remove_members(&group_id, identities)?)
    }

    pub fn encrypt(&mut self, group_id: Vec<u8>, plaintext: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        Ok(self.inner.encrypt(&group_id, plaintext)?)
    }

    pub fn process(
        &mut self,
        group_id: Vec<u8>,
        message: Vec<u8>,
    ) -> anyhow::Result<IncomingMessage> {
        use chat_crypto::Incoming;
        let empty = IncomingMessage {
            kind: IncomingKind::Own,
            sender: vec![],
            plaintext: vec![],
            still_member: true,
        };
        Ok(match self.inner.process(&group_id, message)? {
            Incoming::Application { sender, plaintext } => IncomingMessage {
                kind: IncomingKind::Application,
                sender,
                plaintext,
                ..empty
            },
            Incoming::Commit { still_member } => IncomingMessage {
                kind: IncomingKind::Commit,
                still_member,
                ..empty
            },
            Incoming::Proposal => IncomingMessage {
                kind: IncomingKind::Proposal,
                ..empty
            },
            Incoming::Own => empty,
        })
    }

    #[frb(sync)]
    pub fn members(&self, group_id: Vec<u8>) -> anyhow::Result<Vec<Vec<u8>>> {
        Ok(self.inner.members(&group_id)?)
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

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
