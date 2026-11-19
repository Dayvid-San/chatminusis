import 'dart:typed_data';

import '../entities/conversation.dart';

/// Thrown when a commit lost the epoch race (someone else committed first).
class EpochConflictException implements Exception {
  const EpochConflictException();
}

/// Transport for E2EE conversations. The backend only stores and relays
/// opaque blobs; it never sees keys or plaintext. Implemented for Firebase
/// now and Supabase later (stage 11).
abstract class ConversationBackend {
  // Identity and key packages.
  Future<void> publishIdentity(String uid, Uint8List signatureKey);
  Future<Uint8List?> fetchIdentity(String uid);
  Future<void> publishKeyPackages(String uid, List<Uint8List> keyPackages);
  Future<int> countKeyPackages(String uid);

  /// Deletes all of [uid]'s published KeyPackages (after restoring a backup,
  /// their private parts may be missing).
  Future<void> clearKeyPackages(String uid);

  /// Atomically takes (and deletes) one KeyPackage of [uid]; null if none left.
  Future<Uint8List?> claimKeyPackage(String uid);

  // Conversations.
  /// Creates the conversation together with its first commit (epoch 1).
  /// Throws [EpochConflictException] if it already exists.
  Future<void> createConversation({
    required ConversationRecord record,
    required Envelope firstCommit,
    required List<WelcomeOut> welcomes,
  });

  /// Publishes a commit with an epoch compare-and-set: only succeeds when the
  /// server epoch is `commit.epoch - 1`. Membership changes (role or null to
  /// remove) and Welcomes are applied in the same atomic write.
  /// Throws [EpochConflictException] on a lost race.
  Future<void> publishCommit({
    required Envelope commit,
    Map<String, MemberRole?> memberChanges = const {},
    List<WelcomeOut> welcomes = const [],
  });

  Future<void> publishApplication(Envelope message, {required List<String> notifyUids});

  /// Leaves a conversation (removes self from the server membership).
  Future<void> leaveConversation({required String uid, required String conversationId});

  Stream<List<String>> watchConversationIds(String uid);
  Stream<ConversationRecord?> watchConversation(String conversationId);
  Future<ConversationRecord?> getConversation(String conversationId);

  /// Every envelope of the conversation: existing ones first, then new ones.
  Stream<Envelope> watchEnvelopes(String conversationId);

  Stream<WelcomeEnvelope> watchWelcomes(String uid);
  Future<void> deleteWelcome(String uid, String welcomeId);

  /// A member who lost their keys (new device without backup) asks to be
  /// re-invited. Any member with the right to commit membership repairs it.
  Future<void> requestRejoin(String conversationId, String uid);
  Stream<Set<String>> watchRejoinRequests(String conversationId);
  Future<void> clearRejoin(String conversationId, String uid);

  /// Server-generated unique id for a new envelope.
  String newEnvelopeId(String conversationId);
}
