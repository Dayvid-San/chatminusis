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
    this.expiresAt,
  });

  final String id;
  final String conversationId;
  final String senderUid;
  final String text;
  final int timestamp;
  final bool outgoing;

  /// Disappearing messages: milliseconds since epoch, or null.
  final int? expiresAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'c': conversationId,
    's': senderUid,
    't': text,
    'ts': timestamp,
    'o': outgoing,
    if (expiresAt != null) 'x': expiresAt,
  };

  factory DecryptedMessage.fromJson(Map<String, Object?> j) => DecryptedMessage(
    id: j['id'] as String,
    conversationId: j['c'] as String,
    senderUid: j['s'] as String,
    text: j['t'] as String,
    timestamp: j['ts'] as int,
    outgoing: j['o'] as bool,
    expiresAt: j['x'] as int?,
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
}
