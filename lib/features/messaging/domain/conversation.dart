import 'dart:typed_data';

enum ConversationType { direct, group }

enum MemberRole { admin, member }

/// Server-side view of a conversation: who is in it and its MLS epoch.
/// Contains no title, no content: those travel encrypted.
class ConversationRecord {
  const ConversationRecord({
    required this.id,
    required this.type,
    required this.createdBy,
    required this.epoch,
    required this.members,
  });

  final String id;
  final ConversationType type;
  final String createdBy;
  final int epoch;
  final Map<String, MemberRole> members;

  bool isAdmin(String uid) => members[uid] == MemberRole.admin;
}

/// What an envelope claims to hold. [commit]s may only be published by admins;
/// [proposal]s are an ordinary member's request to rotate their own keys.
/// Receivers verify that the MLS content really matches the kind.
enum EnvelopeKind { application, commit, proposal }

/// An opaque MLS message as stored on the server.
class Envelope {
  const Envelope({
    required this.id,
    required this.conversationId,
    required this.sender,
    required this.epoch,
    required this.kind,
    required this.payload,
    this.timestamp = 0,
  });

  final String id;
  final String conversationId;
  final String sender;
  final int epoch;
  final EnvelopeKind kind;
  final Uint8List payload;
  final int timestamp;
}

/// A Welcome addressed to one user, inviting them into a conversation.
class WelcomeEnvelope {
  const WelcomeEnvelope({
    required this.id,
    required this.conversationId,
    required this.from,
    required this.epoch,
    required this.payload,
  });

  final String id;
  final String conversationId;
  final String from;
  final int epoch;
  final Uint8List payload;
}

class WelcomeOut {
  const WelcomeOut({required this.recipientUid, required this.payload});
  final String recipientUid;
  final Uint8List payload;
}

/// A decrypted message kept only on this device (encrypted at rest).
class DecryptedMessage {
  const DecryptedMessage({
    required this.id,
    required this.conversationId,
    required this.senderUid,
    required this.text,
    required this.timestamp,
    required this.outgoing,
    this.viewedUntil,
    this.hidden = false,
    this.reveal,
  });

  final String id;
  final String conversationId;
  final String senderUid;
  final String text;
  final int timestamp;
  final bool outgoing;

  /// Visibility window of a received message: milliseconds since epoch until
  /// which it is shown, or null while it has not been displayed yet. Stored.
  final int? viewedUntil;

  /// Computed when read from the service, never stored: the conversation's
  /// window has run out for this message. A hidden message carries no text.
  final bool hidden;

  /// A hidden message the receiver asked to see again: `req` while waiting for
  /// the sender's answer, `den` once the sender refused. Stored.
  final String? reveal;

  DecryptedMessage copyWith({int? viewedUntil, bool? hidden, String? text, String? reveal, bool clearReveal = false}) =>
      DecryptedMessage(
        id: id,
        conversationId: conversationId,
        senderUid: senderUid,
        text: text ?? this.text,
        timestamp: timestamp,
        outgoing: outgoing,
        viewedUntil: viewedUntil ?? this.viewedUntil,
        hidden: hidden ?? this.hidden,
        reveal: clearReveal ? null : reveal ?? this.reveal,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'c': conversationId,
    's': senderUid,
    't': text,
    'ts': timestamp,
    'o': outgoing,
    if (viewedUntil != null) 'v': viewedUntil,
    if (reveal != null) 'rv': reveal,
  };

  factory DecryptedMessage.fromJson(Map<String, Object?> j) => DecryptedMessage(
    id: j['id'] as String,
    conversationId: j['c'] as String,
    senderUid: j['s'] as String,
    text: j['t'] as String,
    timestamp: j['ts'] as int,
    outgoing: j['o'] as bool,
    viewedUntil: j['v'] as int?,
    reveal: j['rv'] as String?,
  );
}

/// What the conversation list shows.
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.type,
    required this.memberUids,
    required this.isAdmin,
    this.title,
    this.lastMessage,
    this.pendingWelcome = false,
    this.membershipMismatch = false,
    this.keyChanged = false,
    this.visibilityWindow,
    this.visibilityProposal,
    this.revealRequests = const [],
    this.ended = false,
  });

  final String id;
  final ConversationType type;

  /// Members according to the encrypted MLS group (authoritative).
  final List<String> memberUids;
  final bool isAdmin;

  /// Group title (decrypted). Null for direct chats.
  final String? title;
  final DecryptedMessage? lastMessage;

  /// Invited on the server but the encrypted Welcome was not processed yet.
  final bool pendingWelcome;

  /// Server membership differs from the cryptographic group.
  final bool membershipMismatch;

  /// A member's identity key changed since it was pinned.
  final bool keyChanged;

  /// How long a received message stays visible after being shown, set for the
  /// whole conversation. Null: messages are never hidden.
  final Duration? visibilityWindow;

  /// A change of the window that the members are still agreeing on.
  final VisibilityProposal? visibilityProposal;

  /// People asking to see again a message of mine that they can no longer see.
  /// I decide, one by one.
  final List<RevealRequest> revealRequests;

  /// This device left or was removed: the history stays here (only the user
  /// deletes it) but nothing new can be sent or received.
  final bool ended;
}

/// A proposal to change the conversation's visibility window. It takes effect
/// only when every current member accepted it; otherwise the window stays.
class VisibilityProposal {
  const VisibilityProposal({
    required this.id,
    required this.seconds,
    required this.proposer,
    required this.acks,
    required this.members,
  });

  final String id;

  /// 0 means "never hide".
  final int seconds;
  final String proposer;

  /// Members who accepted (the proposer counts).
  final Set<String> acks;

  /// The members when it was proposed: if they change, the proposal is dropped.
  final Set<String> members;

  VisibilityProposal withAck(String uid) =>
      VisibilityProposal(id: id, seconds: seconds, proposer: proposer, acks: {...acks, uid}, members: members);

  Map<String, Object?> toJson() => {'id': id, 's': seconds, 'p': proposer, 'a': acks.toList(), 'm': members.toList()};

  factory VisibilityProposal.fromJson(Map<String, Object?> j) => VisibilityProposal(
    id: j['id'] as String,
    seconds: j['s'] as int,
    proposer: j['p'] as String,
    acks: (j['a'] as List).cast<String>().toSet(),
    members: (j['m'] as List).cast<String>().toSet(),
  );
}

/// [requester] asks to see again the message [messageId] that I sent.
class RevealRequest {
  const RevealRequest({required this.messageId, required this.requester, this.text = ''});

  final String messageId;
  final String requester;

  /// My own message's text (filled in when read from the service).
  final String text;
}
